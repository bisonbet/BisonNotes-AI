//
//  AudioPlayerView.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let recording: AudioRecordingFile
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var duration: TimeInterval = 0
    @State private var showingShareSheet = false
    @State private var editableTitle: String = ""
    @State private var currentSavedTitle: String = ""
    @State private var isUpdatingTitle = false
    @State private var titleUpdateError: String?
    @State private var audioExportURL: URL?
    @State private var audioExportError: String?
    @State private var audioLoadError: String?

    // Transcript-from-recording flow
    @ObservedObject private var transcriptionStarter = TranscriptionStarter.shared
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    @State private var showingAudioCleanupPrompt = false
    @State private var recordingPendingTranscription: RecordingEntry?
    @State private var selectedRecordingForTranscript: RecordingEntry?
    @State private var transcriptStateRefresh = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Player")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(recording.dateString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: prepareAudioExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Export Audio")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        RecordingTitleEditorView(
                            title: $editableTitle,
                            savedTitle: currentSavedTitle,
                            isSaving: isUpdatingTitle,
                            onSave: updateRecordingTitle
                        )
                        .frame(maxWidth: .infinity)

                        transcriptActionRow
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 18) {
                        if duration > 0 {
                            AudioScrubber(
                                currentTime: recorderVM.playingTime,
                                duration: duration,
                                onSeek: { time in
                                    recorderVM.seekToTime(time)
                                }
                            )
                        } else if let audioLoadError {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title2)
                                    .foregroundColor(.orange)
                                Text(audioLoadError)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(height: 86)
                        } else {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                Text("Loading audio...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(height: 70)
                        }

                        HStack(spacing: 30) {
                            Button(action: skipBackward) {
                                VStack(spacing: 4) {
                                    Image(systemName: "gobackward.15")
                                        .font(.title2)
                                    Text("15s")
                                        .font(.caption2)
                                }
                                .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)

                            Button(action: togglePlayback) {
                                Image(systemName: recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(audioLoadError != nil)

                            Button(action: skipForward) {
                                VStack(spacing: 4) {
                                    Image(systemName: "goforward.15")
                                        .font(.title2)
                                    Text("15s")
                                        .font(.caption2)
                                }
                                .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    }
                    .padding(18)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button("Close") {
                        if recorderVM.isPlaying {
                            recorderVM.stopPlaying()
                        }
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingShareSheet, onDismiss: {
            audioExportURL = nil
            RecordingArchiveService.shared.cleanupAudioExportStaging()
        }) {
            if let audioExportURL {
                ShareSheet(activityItems: [audioExportURL])
            }
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
                if let pending = recordingPendingTranscription {
                    recordingPendingTranscription = nil
                    transcriptionStarter.startTranscription(for: pending, cleanFirst: true, appCoordinator: appCoordinator)
                }
            }
            Button("Transcribe As-Is") {
                if let pending = recordingPendingTranscription {
                    recordingPendingTranscription = nil
                    transcriptionStarter.startTranscription(for: pending, cleanFirst: false, appCoordinator: appCoordinator)
                }
            }
            Button("Cancel", role: .cancel) {
                recordingPendingTranscription = nil
            }
        } message: {
            Text("Cleaning reduces static and normalizes volume, which can improve transcription accuracy. The original audio file is not changed.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            transcriptStateRefresh.toggle()
        }
        .onAppear {
            AppLog.shared.recording("AudioPlayerView appeared", level: .debug)
            editableTitle = recording.name
            currentSavedTitle = recording.name
            setupAudio()
        }
        .alert("Unable to Update Title", isPresented: Binding(
            get: { titleUpdateError != nil },
            set: { if !$0 { titleUpdateError = nil } }
        )) {
            Button("OK", role: .cancel) {
                titleUpdateError = nil
            }
        } message: {
            Text(titleUpdateError ?? "Unknown error")
        }
        .alert("Unable to Export Audio", isPresented: Binding(
            get: { audioExportError != nil },
            set: { if !$0 { audioExportError = nil } }
        )) {
            Button("OK", role: .cancel) {
                audioExportError = nil
            }
        } message: {
            Text(audioExportError ?? "Unknown error")
        }
        .onDisappear {
            AppLog.shared.recording("AudioPlayerView disappeared", level: .debug)
            if recorderVM.isPlaying {
                recorderVM.stopPlaying()
            }
        }
    }

    /// "Generate Transcript" action shown in the player. Disappears once a transcript exists —
    /// users edit transcripts from the Transcripts tab. Resolves the RecordingEntry on demand
    /// so state reflects the latest Core Data state (post-transcription, post-rename).
    @ViewBuilder
    private var transcriptActionRow: some View {
        if let entry = appCoordinator.getRecording(url: recording.url),
           entry.transcript == nil {
            let recordingId = entry.id ?? UUID()
            let isProcessing = transcriptionStarter.isCleaning(recordingId)
                || transcriptionStarter.isQueuedForCleanup(recordingId)
                || transcriptionStarter.hasActiveTranscriptionJob(for: entry, appCoordinator: appCoordinator)

            Button(action: {
                if !isProcessing, audioLoadError == nil {
                    recordingPendingTranscription = entry
                    showingAudioCleanupPrompt = true
                }
            }) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                        Text("Transcribing…")
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
            .disabled(isProcessing || audioLoadError != nil)
            .id("transcript-action-\(recordingId)-\(isProcessing)-\(transcriptStateRefresh)")
        }
    }

    private func setupAudio() {
        AppLog.shared.recording("AudioPlayerView setupAudio called", level: .debug)

        // Get duration from the audio file
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            guard player.duration.isFinite, player.duration > 0 else {
                throw NSError(
                    domain: "AudioPlayerView",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "This audio file appears to be empty or corrupted."]
                )
            }
            duration = player.duration
            audioLoadError = nil
            AppLog.shared.recording("Duration loaded from AVAudioPlayer: \(duration)", level: .debug)
        } catch {
            AppLog.shared.recording("Error getting audio duration: \(error)", level: .error)
            // Fallback to recording duration if available
            duration = recording.duration
            if duration <= 0 {
                audioLoadError = "This audio file appears to be empty or corrupted."
            }
        }
    }

    private func togglePlayback() {
        AppLog.shared.recording("Toggle playback - currently playing: \(recorderVM.isPlaying)", level: .debug)
        if recorderVM.isPlaying {
            recorderVM.stopPlaying()
        } else {
            recorderVM.playRecording(url: recording.url)
        }
    }

    private func skipBackward() {
        let currentTime = recorderVM.getCurrentTime()
        let newTime = max(currentTime - 15.0, 0)
        recorderVM.seekToTime(newTime)
    }

    private func skipForward() {
        let currentTime = recorderVM.getCurrentTime()
        let newTime = min(currentTime + 15.0, duration)
        recorderVM.seekToTime(newTime)
    }

    private func prepareAudioExport() {
        let exportTitle = currentSavedTitle.isEmpty ? recording.name : currentSavedTitle
        guard let stagedURL = RecordingArchiveService.shared.prepareAudioExportURL(
            sourceURL: recording.url,
            title: exportTitle,
            recordingDate: recording.date
        ) else {
            audioExportError = "The audio file could not be prepared for export."
            return
        }

        audioExportURL = stagedURL
        showingShareSheet = true
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateRecordingTitle() {
        let trimmedName = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUpdatingTitle,
              !trimmedName.isEmpty,
              trimmedName != currentSavedTitle else {
            return
        }

        guard let recordingEntry = appCoordinator.getRecording(url: recording.url),
              let recordingId = recordingEntry.id else {
            titleUpdateError = "Could not find this recording in storage."
            return
        }

        isUpdatingTitle = true

        Task {
            do {
                // Updates the display name only (recordingName field in Core Data).
                // Physical audio file renaming is not performed here, consistent with SummaryDetailView.
                try appCoordinator.coreDataManager.updateRecordingName(for: recordingId, newName: trimmedName)

                await MainActor.run {
                    isUpdatingTitle = false
                    currentSavedTitle = trimmedName
                    editableTitle = trimmedName
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RecordingRenamed"),
                        object: nil,
                        userInfo: ["recordingId": recordingId, "newName": trimmedName]
                    )
                    AppLog.shared.recording("Updated recording title from AudioPlayerView to: \(trimmedName)")
                }
            } catch {
                await MainActor.run {
                    isUpdatingTitle = false
                    titleUpdateError = error.localizedDescription
                }
            }
        }
    }
}

/// Reusable title-editing row shared by AudioPlayerView and EditableTranscriptView.
struct RecordingTitleEditorView: View {
    @Binding var title: String
    let savedTitle: String
    let isSaving: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording Title")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                TextField("Enter title", text: $title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(isSaving)
                    .onSubmit { onSave() }

                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(
                    isSaving ||
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    title.trimmingCharacters(in: .whitespacesAndNewlines) == savedTitle
                )
            }
        }
    }
}
