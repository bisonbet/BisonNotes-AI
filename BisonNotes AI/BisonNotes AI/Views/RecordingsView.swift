//
//  RecordingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI

struct RecordingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var importManager: FileImportManager
    @EnvironmentObject var transcriptImportManager: TranscriptImportManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var textDocumentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var videoPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var webImportManager = WebImportManager()
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var showingRecordingsList = false
    @State private var showingBackgroundProcessing = false
    @State private var showingWebImport = false
    @State private var showingRecorderError = false
    @State private var recorderErrorMessage = ""

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
            }
            .foregroundColor(.white)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                recorderVM.isStartingRecording
                    ? Color.gray
                    : Color(red: 0.0, green: 0.32, blue: 0.68)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Record")
                                .font(.largeTitle.weight(.bold))
                                .foregroundColor(.primary)

                            Text("Capture audio, import files, and pick up previous recordings.")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        Button(action: {
                            if let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/") {
                                openURL(url)
                            }
                        }) {
                            Image(systemName: "questionmark.circle")
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Help")
                    }

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

                    VStack(spacing: 14) {
                        if recorderVM.isRecording {
                            recordingTimerView
                            recordingControls
                        } else {
                            startRecordingButton
                        }

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
                                showingRecordingsList = true
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
                                // Directly trigger document picker for audio files
                                documentPickerCoordinator.selectAudioFiles { urls in
                                    if !urls.isEmpty {
                                        Task {
                                            await importManager.importAudioFiles(from: urls)
                                        }
                                    }
                                }
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
                            // videoPickerCoordinator.selectVideoFiles { ... }

                            homeActionButton(
                                HomeActionConfig(
                                    title: "Import Transcripts",
                                    subtitle: "Add text files",
                                    systemImage: "doc.text",
                                    tint: .purple,
                                    accessibilityIdentifier: BisonNotesAccessibilityID.importTranscriptButton
                                )
                            ) {
                                // Trigger document picker for text files
                                textDocumentPickerCoordinator.selectTextFiles { urls in
                                    if !urls.isEmpty {
                                        Task {
                                            await transcriptImportManager.importTranscriptFiles(from: urls)
                                        }
                                    }
                                }
                            }
                        }

                        if recorderVM.isRecording {
                            recordingStatusPanel
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
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
            }
            .sheet(isPresented: $textDocumentPickerCoordinator.isShowingPicker) {
                TextDocumentPicker(isPresented: $textDocumentPickerCoordinator.isShowingPicker, coordinator: textDocumentPickerCoordinator)
            }
            .sheet(isPresented: $showingWebImport) {
                WebImportSheet(
                    webImportManager: webImportManager,
                    fileImportManager: importManager,
                    transcriptImportManager: transcriptImportManager
                )
            }
            // Video picker sheet hidden — feature not yet ready for users
            // .sheet(isPresented: $videoPickerCoordinator.isShowingPicker) { ... }
            .sheet(isPresented: $showingBackgroundProcessing) {
                BackgroundProcessingView()
            }
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
                documentPickerCoordinator.selectAudioFiles { urls in
                    if !urls.isEmpty {
                        Task {
                            await importManager.importAudioFiles(from: urls)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ImportTranscriptFromMenu"))) { _ in
                textDocumentPickerCoordinator.selectTextFiles { urls in
                    if !urls.isEmpty {
                        Task {
                            await transcriptImportManager.importTranscriptFiles(from: urls)
                        }
                    }
                }
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
        .sheet(isPresented: $showingRecordingsList) {
            RecordingsListView()
                .environment(\.isEmbeddedInSplitView, false)
                .environmentObject(recorderVM)
        }
    }

    private var recordingStatusPanel: some View {
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

            // Live transcript display
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
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
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
            showingBackgroundProcessing = true
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
