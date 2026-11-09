//
//  RecordingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var importManager: FileImportManager
    @EnvironmentObject var transcriptImportManager: TranscriptImportManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var showingFileImporter = false
    @State private var fileImportKind: FileImportKind = .audio
    @StateObject private var webImportManager = WebImportManager()
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var showingRecordingsList = false
    @State private var showingBackgroundProcessing = false
    @State private var showingWebImport = false
    @State private var showingRecorderError = false
    @State private var recorderErrorMessage = ""

    private enum FileImportKind {
        case audio
        case transcript
    }

    private struct RecordingActionConfig {
        let title: String
        let systemImage: String
        let tint: Color
        let accessibilityIdentifier: String
        let accessibilityHint: String
    }

    private struct HomeActionConfig {
        let title: String
        let subtitle: String
        let systemImage: String
        let tint: Color
        let accessibilityIdentifier: String
    }

    // MARK: - Recording Controls

    @ViewBuilder
    private var recordingTimerView: some View {
        HStack(spacing: 8) {
            Text(recorderVM.formatTime(recorderVM.recordingTime))
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(recorderVM.isPaused ? .secondary : .accentColor)
                .monospacedDigit()
            if recorderVM.isPaused {
                Text("Paused")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording timer")
        .accessibilityValue(
            AccessibilitySupport.recordingTimerValue(
                recordingTime: recorderVM.recordingTime,
                isPaused: recorderVM.isPaused
            )
        )
        .accessibilityIdentifier(BisonNotesAccessibilityID.recordingTimer)
    }

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 12) {
            recordingActionButton(
                RecordingActionConfig(
                    title: recorderVM.isPaused ? "Resume" : "Pause",
                    systemImage: recorderVM.isPaused ? "play.circle.fill" : "pause.circle.fill",
                    tint: .accentColor,
                    accessibilityIdentifier: recorderVM.isPaused
                        ? BisonNotesAccessibilityID.resumeRecordingButton
                        : BisonNotesAccessibilityID.pauseRecordingButton,
                    accessibilityHint: recorderVM.isPaused
                        ? "Resumes the current recording."
                        : "Pauses capture without saving the recording."
                )
            ) {
                if recorderVM.isPaused {
                    recorderVM.resumeRecording()
                } else {
                    recorderVM.pauseRecording()
                }
            }

            recordingActionButton(
                RecordingActionConfig(
                    title: "Stop",
                    systemImage: "stop.circle.fill",
                    tint: .red,
                    accessibilityIdentifier: BisonNotesAccessibilityID.stopRecordingButton,
                    accessibilityHint: "Stops and saves the current recording."
                )
            ) {
                recorderVM.stopRecording()
            }
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var startRecordingButton: some View {
        Button(action: { recorderVM.startRecording() }) {
            HStack(spacing: 12) {
                if recorderVM.isStartingRecording {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                }
                Text(recorderVM.isStartingRecording ? "Starting..." : "Start Recording")
                    .font(.headline)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    // A hard `.frame(height: 56)` clipped this label once Dynamic
                    // Type grew past the default. Padding plus a minimum height
                    // keeps the 56pt button at standard sizes and lets it grow
                    // and wrap beyond them.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            // 12 keeps the intrinsic height under `minHeight` at standard Dynamic
            // Type, so the button still measures exactly 56pt there and the rows
            // below it are not nudged into the container edge.
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                recorderVM.isStartingRecording
                    ? Color.gray
                    : Color.bisonPrimaryAction
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(recorderVM.isStartingRecording)
        .accessibilityLabel(recorderVM.isStartingRecording ? "Starting recording" : "Start Recording")
        .accessibilityHint("Starts a new audio recording.")
        .accessibilityValue(recorderVM.isStartingRecording ? "Starting" : "Ready")
        .accessibilityIdentifier(BisonNotesAccessibilityID.startRecordingButton)
    }

    // File-importer URLs are security-scoped; hold access for the whole import.
    private func handleImport(_ result: Result<[URL], Error>, using importFiles: @escaping ([URL]) async -> Void) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            await importFiles(urls)
        }
    }

    private var fileImportContentTypes: [UTType] {
        switch fileImportKind {
        case .audio:
            return [.audio]
        case .transcript:
            return Self.transcriptContentTypes
        }
    }

    private func beginFileImport(_ kind: FileImportKind) {
        fileImportKind = kind
        showingFileImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let importKind = fileImportKind
        switch importKind {
        case .audio:
            handleImport(result) { urls in
                await importManager.importAudioFiles(from: urls)
            }
        case .transcript:
            handleImport(result) { urls in
                await transcriptImportManager.importTranscriptFiles(from: urls)
            }
        }
    }

    private static let transcriptContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf]
        types.append(UTType(importedAs: "org.openxmlformats.wordprocessingml.document"))
        for ext in ["md", "markdown", "docx", "doc"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()

    private func recordingActionButton(
        _ config: RecordingActionConfig,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: config.systemImage)
                    .font(.title3)
                Text(config.title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(config.tint)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(config.title)
        .accessibilityHint(config.accessibilityHint)
        .accessibilityIdentifier(config.accessibilityIdentifier)
    }

    var body: some View {
        AdaptiveNavigationWrapper {
            recordContent
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground))
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        openURL(BisonNotesDocumentation.releaseGuideURL)
                    }) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }
            }
            #endif
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: fileImportContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showingWebImport) {
                WebImportSheet(
                    webImportManager: webImportManager,
                    fileImportManager: importManager,
                    transcriptImportManager: transcriptImportManager
                )
                .nativeMacModalSizing(width: 700, height: 620)
                .nativeMacPresentationContext(.modalSheet)
            }
            // Video import hidden — feature not yet ready for users
#if !os(macOS)
            .sheet(isPresented: $showingBackgroundProcessing) {
                BackgroundProcessingView()
            }
#endif
            .alert("Audio Import Results", isPresented: $importManager.showingImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let results = importManager.importResults {
                    Text(results.summary)
                }
            }
            .alert("Transcript Import Results", isPresented: $transcriptImportManager.showingImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let results = transcriptImportManager.importResults {
                    Text(results.summary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleRecording"))) { _ in
                if recorderVM.isRecording {
                    recorderVM.stopRecording()
                } else {
                    recorderVM.startRecording()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ImportAudioFromMenu"))) { _ in
                beginFileImport(.audio)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ImportTranscriptFromMenu"))) { _ in
                beginFileImport(.transcript)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSNotification.Name("ImportFromLinkFromMenu"))
            ) { _ in
                showingWebImport = true
            }
            .onChange(of: recorderVM.errorMessage) { _, message in
                if let message, !message.isEmpty {
                    recorderErrorMessage = message
                    showingRecorderError = true
                    recorderVM.errorMessage = nil
                }
            }
            .alert("Recording Error", isPresented: $showingRecorderError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recorderErrorMessage)
            }
        }
#if !os(macOS)
        .sheet(isPresented: $showingRecordingsList) {
            RecordingsListView()
                .environmentObject(recorderVM)
        }
#endif
    }

    // MARK: - Layout

    /// On iOS 27.1 the controls sit beside the live transcript and the library
    /// and import actions (`SideBySideArrangement`), either side of iPhone Duo's
    /// fold. Without room beside them the primary shows the original single
    /// column, so nothing is out of reach. Earlier systems and macOS keep the
    /// single column.
    @ViewBuilder
    private var recordContent: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            SideBySideArrangement { layout in
                switch layout {
                case .single:
                    stackedRecordContent
                case .sideBySide:
                    splitPrimaryColumn(showsHero: showsHero)
                case .topAndBottom:
                    // Laptop pose: Start Recording on the top half, above the
                    // fold; the library and imports below it. Half a screen has
                    // no room for the logo.
                    splitPrimaryColumn(showsHero: false)
                }
            } secondary: {
                splitSecondaryColumn
            }
        } else {
            stackedRecordContent
        }
        #else
        stackedRecordContent
        #endif
    }

    private func splitPrimaryColumn(showsHero: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                recordHeader
                if showsHero {
                    recordHero
                }
                controlsCard(includingLiveTranscript: false)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var splitSecondaryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if recorderVM.isRecording {
                    liveTranscriptPanel(lineLimit: nil)
                }
                homeActionsCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// The single column every system before iOS 27.1 shows.
    private var stackedRecordContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                recordHeader
                if showsHero {
                    recordHero
                }
                VStack(spacing: 14) {
                    recordingButtons
                    homeActionButtons
                    if recorderVM.isRecording {
                        recordingStatusPanel(includingLiveTranscript: true)
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// Short and wide — iPhone Duo's outer display in landscape, an iPhone on
    /// its side — has no room for the logo above the record button.
    private var showsHero: Bool {
        #if os(iOS)
        verticalSizeClass != .compact
        #else
        true
        #endif
    }

    private var recordHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)

                if showsHero {
                    Text("Capture audio, import files, and pick up previous recordings.")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }

            Spacer()

            // On iOS Help is a toolbar item, so iPhone Duo can move
            // it into its vertical bar.
            #if os(macOS)
            Button(action: {
                openURL(BisonNotesDocumentation.releaseGuideURL)
            }) {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help")
            #endif
        }
    }

    private var recordHero: some View {
        VStack(spacing: 18) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 116, height: 116)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("BisonNotes AI")
                    .font(.title.weight(.bold))
                    .foregroundColor(.primary)

                Text("Ready when you are.")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var recordingButtons: some View {
        if recorderVM.isRecording {
            recordingTimerView
            recordingControls
        } else {
            startRecordingButton
        }
    }

    private func controlsCard(includingLiveTranscript: Bool) -> some View {
        VStack(spacing: 14) {
            recordingButtons
            if recorderVM.isRecording {
                recordingStatusPanel(includingLiveTranscript: includingLiveTranscript)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var homeActionsCard: some View {
        homeActionButtons
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var homeActionButtons: some View {
        VStack(spacing: 10) {
            homeActionButton(
                HomeActionConfig(
                    title: "View Recordings",
                    subtitle: "Browse saved audio",
                    systemImage: "list.bullet",
                    tint: .accentColor,
                    accessibilityIdentifier: BisonNotesAccessibilityID.viewRecordingsButton
                )
            ) {
                presentRecordingsLibrary()
            }

            homeActionButton(
                HomeActionConfig(
                    title: "Import Audio Files",
                    subtitle: "Add audio from Files",
                    systemImage: "plus.circle",
                    tint: .green,
                    accessibilityIdentifier: BisonNotesAccessibilityID.importAudioButton
                )
            ) {
                beginFileImport(.audio)
            }

            homeActionButton(
                HomeActionConfig(
                    title: "Import From Link",
                    subtitle: "Add web audio or captions",
                    systemImage: "link.badge.plus",
                    tint: .blue,
                    accessibilityIdentifier: BisonNotesAccessibilityID.importLinkButton
                )
            ) {
                showingWebImport = true
            }

            // Video import button hidden — feature not yet ready for users

            homeActionButton(
                HomeActionConfig(
                    title: "Import Transcripts",
                    subtitle: "Add text files",
                    systemImage: "doc.text",
                    tint: .purple,
                    accessibilityIdentifier: BisonNotesAccessibilityID.importTranscriptButton
                )
            ) {
                beginFileImport(.transcript)
            }
        }
    }

    private func recordingStatusPanel(includingLiveTranscript: Bool) -> some View {
        VStack(spacing: 12) {
            // Phase 5: State-aware status indicator
            HStack(spacing: 8) {
                statusIndicator(for: recorderVM.recordingState)
                Text(statusText(for: recorderVM.recordingState))
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording status")
            .accessibilityValue(statusText(for: recorderVM.recordingState))

            // Phase 5: Warning banners
            warningBannersView()

            // Background recording indicator
            if recorderVM.isRecording {
                Label("Background recording enabled", systemImage: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .accessibilityLabel("Background recording enabled")
            }

            // Beside the controls on iOS 27.1, the live transcript has its own
            // side; in the single column it stays under the status.
            if includingLiveTranscript {
                liveTranscriptPanel(lineLimit: 4)
            }
        }
    }

    @ViewBuilder
    private func liveTranscriptPanel(lineLimit: Int?) -> some View {
        if !recorderVM.liveTranscriptText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text("Live Transcript")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                }
                Text(recorderVM.liveTranscriptText)
                    .font(lineLimit == nil ? .body : .caption)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(lineLimit)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityCard(
                label: "Live Transcript",
                value: recorderVM.liveTranscriptText,
                hint: "Updates as speech is recognized during recording."
            )
            .accessibilityIdentifier(BisonNotesAccessibilityID.liveTranscript)
        }
    }

    private func homeActionButton(
        _ config: HomeActionConfig,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: config.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(config.tint)
                    .frame(width: 38, height: 38)
                    .background(config.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(config.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(config.subtitle)
                        .font(.caption)
                        .foregroundColor(.primary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(config.title)
        .accessibilityValue(config.subtitle)
        .accessibilityHint("Activates \(config.title).")
        .accessibilityIdentifier(config.accessibilityIdentifier)
    }

    private var backgroundProcessingIndicator: some View {
        Button(action: {
            presentBackgroundProcessing()
        }) {
            HStack {
                Image(systemName: "gear.circle.fill")
                    .font(.title3)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Processing")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    let activeJobs = processingManager.activeJobs.filter { $0.status == .processing }.count
                    let completedJobs = processingManager.activeJobs.filter { $0.status == .completed }.count
                    Text("\(activeJobs) active, \(completedJobs) completed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 40)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func presentRecordingsLibrary() {
        #if os(macOS)
        openWindow(id: NativeWindowID.recordings)
        #else
        showingRecordingsList = true
        #endif
    }

    private func presentBackgroundProcessing() {
        #if os(macOS)
        openWindow(id: NativeWindowID.backgroundProcessing)
        #else
        showingBackgroundProcessing = true
        #endif
    }

    // MARK: - Phase 5: UI Helper Methods

    @State private var animationActive = true

    @ViewBuilder
    private func statusIndicator(for state: AudioRecorderViewModel.RecordingState) -> some View {
        Group {
            switch state {
            case .recording:
                // Animated pulsing red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(!reduceMotion && animationActive ? 1.2 : 1.0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                        value: animationActive
                    )

            case .waitingForMicrophone:
                // Orange warning dot
                Circle()
                    .fill(Color.orange)
                    .frame(width: 12, height: 12)

            case .interrupted:
                // Yellow paused dot
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)

            case .waitingForUserDecision:
                // Blue waiting dot
                Circle()
                    .fill(Color.blue)
                    .frame(width: 12, height: 12)

            default:
                // Gray inactive dot
                Circle()
                    .fill(Color.gray)
                    .frame(width: 12, height: 12)
            }
        }
        .onAppear {
            animationActive = !reduceMotion
        }
        .accessibilityHidden(true)
    }

    private func statusText(for state: AudioRecorderViewModel.RecordingState) -> String {
        switch state {
        case .recording:
            return "Recording..."

        case .waitingForMicrophone(let disconnectedAt):
            let elapsed = Date().timeIntervalSince(disconnectedAt)
            return "Waiting for microphone (\(Int(elapsed))s)"

        case .interrupted(.phoneCall, _):
            return "Paused for phone call"

        case .interrupted(.microphoneDisconnected, _):
            return "Microphone disconnected"

        case .interrupted(.systemInterruption, _):
            return "Paused by system"

        case .interrupted(.backgroundTimeExpiring, _):
            return "Background time expiring"

        case .waitingForUserDecision(let duration):
            return "Call ended (\(Int(duration/60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s) - Choose action"

        case .merging:
            return "Merging segments..."

        case .error(let message):
            return "Error: \(message)"

        default:
            return "Recording..."
        }
    }

    @ViewBuilder
    private func warningBannersView() -> some View {
        VStack(spacing: 8) {
            // Duration warning
            if recorderVM.recordingTime >= 13500 { // DURATION_WARNING_THRESHOLD
                let remainingMinutes = Int((14400 - recorderVM.recordingTime) / 60) // MAX - current
                warningBanner(
                    icon: "clock.fill",
                    message: "\(remainingMinutes) min until 4-hour limit",
                    color: .orange
                )
            }
        }
    }

    private func warningBanner(icon: String, message: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundColor(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }
}
