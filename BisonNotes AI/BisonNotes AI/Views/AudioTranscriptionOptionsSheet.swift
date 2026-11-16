import SwiftUI

/// Shared by Recordings and Transcripts so the preparation choice always has
/// the same readable text, opaque background and explicit actions.
struct AudioTranscriptionOptionsSheet: View {
    let recording: RecordingEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var appCoordinator: AppDataCoordinator
    @ObservedObject private var transcriptionStarter = TranscriptionStarter.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Clean audio first?")
                        .font(.title2.bold())

                    Text("Cleaning reduces static and evens out volume.")
                        .font(.body)

                    Text("Original audio stays unchanged.")
                        .font(.body)

                    VStack(spacing: 12) {
                        Button {
                            transcribe(cleanFirst: true)
                        } label: {
                            Text("Clean & Transcribe")
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LibraryPrimaryActionButtonStyle())
                        .accessibilityIdentifier("bisonnotes.transcription-options.clean")

                        Button {
                            transcribe(cleanFirst: false)
                        } label: {
                            Text("Transcribe As-Is")
                                .multilineTextAlignment(.center)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .accessibilityIdentifier("bisonnotes.transcription-options.original")
                    }
                }
                .foregroundStyle(.primary)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("bisonnotes.transcription-options.content")
            .background(Color(.systemBackground))
            .navigationTitle("Transcribe Recording")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("bisonnotes.transcription-options.cancel")
                }
            }
        }
        .tint(.bisonActionForeground)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(500), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
        .nativeMacModalSizing(width: 520, height: 500)
        .nativeMacPresentationContext(.modalSheet)
        .accessibilityIdentifier("bisonnotes.transcription-options")
    }

    private func transcribe(cleanFirst: Bool) {
        dismiss()
        transcriptionStarter.startTranscription(for: recording, cleanFirst: cleanFirst, appCoordinator: appCoordinator)
    }
}
