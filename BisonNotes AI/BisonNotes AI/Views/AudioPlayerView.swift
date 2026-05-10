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

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button(action: prepareAudioExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .padding(.trailing)
            }

            Text("Audio Player")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            RecordingTitleEditorView(
                title: $editableTitle,
                savedTitle: currentSavedTitle,
                isSaving: isUpdatingTitle,
                onSave: updateRecordingTitle
            )
            .frame(maxWidth: .infinity)

            Text("Date: \(recording.dateString)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Audio scrubber with progress and seek functionality
            if duration > 0 {
                AudioScrubber(
                    currentTime: recorderVM.playingTime,
                    duration: duration,
                    onSeek: { time in
                        recorderVM.seekToTime(time)
                    }
                )
                .padding(.horizontal)
                // Remove debug logging - scrubber working properly now
            } else {
                // Loading state
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Loading audio...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 50)
            }
            
            // Playback controls
            HStack(spacing: 30) {
                // Skip backward 15 seconds
                Button(action: skipBackward) {
                    VStack {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                        Text("15s")
                            .font(.caption2)
                    }
                }
                .foregroundColor(.accentColor)
                
                // Main play/pause button
                Button(action: togglePlayback) {
                    Image(systemName: recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                }
                
                // Skip forward 15 seconds
                Button(action: skipForward) {
                    VStack {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                        Text("15s")
                            .font(.caption2)
                    }
                }
                .foregroundColor(.accentColor)
            }
            .padding()
            
            Spacer()
            
            Button("Close") {
                if recorderVM.isPlaying {
                    recorderVM.stopPlaying()
                }
                dismiss()
            }
            .font(.headline)
            .padding()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingShareSheet, onDismiss: {
            audioExportURL = nil
            RecordingArchiveService.shared.cleanupAudioExportStaging()
        }) {
            if let audioExportURL {
                ShareSheet(activityItems: [audioExportURL])
            }
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
    
    private func setupAudio() {
        AppLog.shared.recording("AudioPlayerView setupAudio called", level: .debug)

        // Get duration from the audio file
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            duration = player.duration
            AppLog.shared.recording("Duration loaded from AVAudioPlayer: \(duration)", level: .debug)
        } catch {
            AppLog.shared.recording("Error getting audio duration: \(error)", level: .error)
            // Fallback to recording duration if available
            duration = recording.duration
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
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("Enter title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    .onSubmit { onSave() }

                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving ||
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    title.trimmingCharacters(in: .whitespacesAndNewlines) == savedTitle
                )
            }
        }
    }
}
