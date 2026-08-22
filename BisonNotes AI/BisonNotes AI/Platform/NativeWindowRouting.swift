//
//  NativeWindowRouting.swift
//  BisonNotes AI
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum NativeWindowID {
    static let summary = "summary-detail"
    static let transcript = "transcript-detail"
    static let recording = "recording-detail"
    static let recordings = "recordings-library"
    static let location = "location-detail"
    static let backgroundProcessing = "background-processing"
    static let processingJob = "processing-job-detail"
    static let cloudReview = "cloud-review"
}

/// Describes whether a view is responsible for its own standard window close
/// or needs explicit modal actions. Keeping this in the environment lets
/// dual-use views retain mobile sheet controls without adding them to native
/// Mac windows.
enum NativeMacPresentationContext {
    case embedded
    case modelessWindow
    case modalSheet
}

private struct NativeMacPresentationContextKey: EnvironmentKey {
    static let defaultValue = NativeMacPresentationContext.embedded
}

extension EnvironmentValues {
    var nativeMacPresentationContext: NativeMacPresentationContext {
        get { self[NativeMacPresentationContextKey.self] }
        set { self[NativeMacPresentationContextKey.self] = newValue }
    }
}

/// Settings destinations own their navigation stack on iOS. On native macOS,
/// the Settings scene owns one stack for the entire hierarchy so child panels
/// push in place instead of creating nested navigation containers.
struct PlatformSettingsNavigationStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        content
        #else
        NavigationStack { content }
        #endif
    }
}

extension View {
    func nativeMacPresentationContext(_ context: NativeMacPresentationContext) -> some View {
        environment(\.nativeMacPresentationContext, context)
    }

    /// Supplies a meaningful title to a native Mac window while leaving the
    /// mobile navigation title behavior owned by the calling view.
    @ViewBuilder
    func nativeMacWindowTitle(_ title: String) -> some View {
        #if os(macOS)
        navigationTitle(title)
        #else
        self
        #endif
    }

    /// Gives true modal tasks a bounded Mac viewport. The modal's own List,
    /// Form, ScrollView, Map, or PDF view remains responsible for scrolling.
    @ViewBuilder
    func nativeMacModalSizing(width: CGFloat = 700, height: CGFloat = 620) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
            .presentationSizing(.fitted)
        #else
        self
        #endif
    }

    /// Preserve the iPhone/iPad navigation shell while allowing settings
    /// destinations to participate in the single NavigationStack owned by the
    /// native macOS Settings window.
    @ViewBuilder
    func platformSettingsNavigation() -> some View {
        #if os(macOS)
        self
        #else
        NavigationStack { self }
        #endif
    }

    /// The default macOS Form style uses a two-column preference-grid layout.
    /// That works for short label/control pairs, but badly distorts the rich,
    /// multi-line provider panels used throughout BisonNotes. Grouped form
    /// styling restores a readable full-width hierarchy and native scrolling.
    @ViewBuilder
    func nativeMacSettingsFormStyle() -> some View {
        #if os(macOS)
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
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
            content()
                .nativeMacModalSizing(width: 760, height: 700)
                .nativeMacPresentationContext(.modalSheet)
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
        .nativeMacPresentationContext(.modelessWindow)
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
        .nativeMacPresentationContext(.modelessWindow)
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
        .nativeMacPresentationContext(.modelessWindow)
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
