//
//  NativeWindowRouting.swift
//  BisonNotes AI
//

import SwiftUI

enum NativeWindowID {
    static let summary = "summary-detail"
    static let transcript = "transcript-detail"
    static let recording = "recording-detail"
    static let recordings = "recordings-library"
    static let location = "location-detail"
    static let backgroundProcessing = "background-processing"
    static let processingJob = "processing-job-detail"
}

extension View {
    /// Gives true modal tasks a bounded Mac viewport. The modal's own List,
    /// Form, ScrollView, Map, or PDF view remains responsible for scrolling.
    @ViewBuilder
    func nativeMacModalSizing(width: CGFloat = 700, height: CGFloat = 620) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        self
        #endif
    }

    /// Full-screen covers are appropriate on iPhone but produce trapped,
    /// non-window-like experiences on macOS. Keep them as bounded sheets there.
    @ViewBuilder
    func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented) {
            content().nativeMacModalSizing(width: 760, height: 700)
        }
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

#if os(macOS)
struct NativeTranscriptWindowView: View {
    let recordingID: UUID

    @EnvironmentObject private var recorderVM: AudioRecorderViewModel
    @EnvironmentObject private var appCoordinator: AppDataCoordinator

    var body: some View {
        Group {
            if let recording = appCoordinator.getRecording(id: recordingID) {
                if let transcript = appCoordinator.getTranscriptData(for: recordingID) {
                    EditableTranscriptView(
                        recording: recording,
                        transcript: transcript,
                        transcriptManager: TranscriptManager.shared
                    )
                } else {
                    TranscriptDetailView(recording: recording, transcriptText: "")
                }
            } else {
                missingContent("Transcript Not Available", systemImage: "text.bubble")
            }
        }
        .environmentObject(appCoordinator)
        .environmentObject(recorderVM)
        .frame(minWidth: 680, minHeight: 520)
    }
}

struct NativeRecordingWindowView: View {
    let recordingID: UUID

    @EnvironmentObject private var recorderVM: AudioRecorderViewModel
    @EnvironmentObject private var appCoordinator: AppDataCoordinator

    var body: some View {
        Group {
            if let recording = resolvedRecording {
                AudioPlayerView(recording: recording)
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
            } else {
                missingContent("Recording Not Available", systemImage: "waveform")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var resolvedRecording: RecordingFile? {
        guard let entry = appCoordinator.getRecording(id: recordingID) else { return nil }
        let isArchived = entry.isArchived
        let url = appCoordinator.getAbsoluteURL(for: entry)
            ?? (isArchived ? appCoordinator.getStoredURL(for: entry) : nil)
        guard let url else { return nil }

        return RecordingFile(
            url: url,
            name: entry.recordingName ?? url.deletingPathExtension().lastPathComponent,
            date: entry.recordingDate ?? entry.createdAt ?? Date(),
            duration: entry.duration,
            locationData: appCoordinator.loadLocationData(for: entry),
            isArchived: isArchived,
            archivedAt: entry.archivedAt,
            archiveNote: entry.archiveNote,
            recordingId: entry.id,
            storedFileSize: entry.fileSize,
            isCloudSyncDisabled: entry.isCloudSyncDisabled
        )
    }
}

struct NativeProcessingJobWindowView: View {
    let jobID: UUID

    @ObservedObject private var processingManager = BackgroundProcessingManager.shared

    var body: some View {
        Group {
            if let job = processingManager.activeJobs.first(where: { $0.id == jobID }) {
                JobDetailView(job: job)
            } else {
                missingContent("Job Not Available", systemImage: "gearshape.2")
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

@ViewBuilder
private func missingContent(_ title: String, systemImage: String) -> some View {
    ContentUnavailableView(
        title,
        systemImage: systemImage,
        description: Text("The item may have been deleted or moved.")
    )
}
#endif
