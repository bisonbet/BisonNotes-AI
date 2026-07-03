//
//  RecordingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
#if !targetEnvironment(macCatalyst)
import SafariServices
#endif

struct RecordingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var importManager: FileImportManager
    @EnvironmentObject var transcriptImportManager: TranscriptImportManager
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var textDocumentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var videoPickerCoordinator = DocumentPickerCoordinator()
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var showingRecordingsList = false
    @State private var showingBackgroundProcessing = false
    @State private var showingHelpDocumentation = false
    @State private var showingRecorderError = false
    @State private var recorderErrorMessage = ""

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
    }

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 12) {
            recordingActionButton(
                title: recorderVM.isPaused ? "Resume" : "Pause",
                systemImage: recorderVM.isPaused ? "play.circle.fill" : "pause.circle.fill",
                tint: .accentColor
            ) {
                if recorderVM.isPaused {
                    recorderVM.resumeRecording()
                } else {
                    recorderVM.pauseRecording()
                }
            }

            recordingActionButton(
                title: "Stop",
                systemImage: "stop.circle.fill",
                tint: .red
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
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                Text("Start Recording")
                    .font(.headline)
                    .fontWeight(.bold)
            }
            .foregroundColor(.white)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(BisonNotesAccessibilityID.startRecordingButton)
    }

    private func recordingActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Record")
                                .font(.largeTitle.weight(.bold))
                                .foregroundColor(.primary)

                            Text("Capture audio, import files, and pick up previous recordings.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            showingHelpDocumentation = true
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

                        VStack(spacing: 6) {
                            Text("BisonNotes AI")
                                .font(.title.weight(.bold))
                                .foregroundColor(.primary)

                            Text("Ready when you are.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
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
                                title: "View Recordings",
                                subtitle: "Browse saved audio",
                                systemImage: "list.bullet",
                                tint: .accentColor
                            ) {
                                showingRecordingsList = true
                            }
                            .accessibilityIdentifier(BisonNotesAccessibilityID.viewRecordingsButton)

                            homeActionButton(
                                title: "Import Audio Files",
                                subtitle: "Add audio from Files",
                                systemImage: "plus.circle",
                                tint: .green
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

                            // Video import button hidden — feature not yet ready for users
                            // videoPickerCoordinator.selectVideoFiles { ... }

                            homeActionButton(
                                title: "Import Transcripts",
                                subtitle: "Add text files",
                                systemImage: "doc.text",
                                tint: .purple
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
            .sheet(isPresented: $showingRecordingsList) {
                RecordingsListView()
                    .environmentObject(recorderVM)
            }
            .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
            }
            .sheet(isPresented: $textDocumentPickerCoordinator.isShowingPicker) {
                TextDocumentPicker(isPresented: $textDocumentPickerCoordinator.isShowingPicker, coordinator: textDocumentPickerCoordinator)
            }
            // Video picker sheet hidden — feature not yet ready for users
            // .sheet(isPresented: $videoPickerCoordinator.isShowingPicker) { ... }
            .sheet(isPresented: $showingBackgroundProcessing) {
                BackgroundProcessingView()
            }
            .sheet(isPresented: $showingHelpDocumentation) {
                #if !targetEnvironment(macCatalyst)
                if let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/") {
                    SafariView(url: url)
                }
                #endif
            }
            .onChange(of: showingHelpDocumentation) { _, isShowing in
                #if targetEnvironment(macCatalyst)
                if isShowing, let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/") {
                    UIApplication.shared.open(url)
                    showingHelpDocumentation = false
                }
                #endif
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

            // Phase 5: Warning banners
            warningBannersView()

            // Background recording indicator
            if recorderVM.isRecording {
                Label("Background recording enabled", systemImage: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
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
            }
        }
    }

    private func homeActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    .scaleEffect(animationActive ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: animationActive)

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
            animationActive = true
        }
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

// MARK: - Safari View Wrapper
// SafariView is now in Views/SafariView.swift
