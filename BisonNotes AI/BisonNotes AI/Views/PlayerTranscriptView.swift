//
//  PlayerTranscriptView.swift
//  BisonNotes AI
//
//  The recording's transcript beside the player, following playback: the
//  segment being played is highlighted and kept in view, and tapping a segment
//  plays from there. M4 of docs/iphone-duo-implementation-plan.md — the player
//  and its transcript sit either side of iPhone Duo's fold when there is room.
//

import SwiftUI

struct PlayerTranscriptView: View {
    let recordingURL: URL
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var transcript: TranscriptData?

    var body: some View {
        Group {
            if let transcript, !transcript.segments.isEmpty {
                segmentList(transcript)
            } else {
                ContentUnavailableView(
                    "No Transcript Yet",
                    systemImage: "text.bubble",
                    description: Text("Generate a transcript to read along while the recording plays.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier(BisonNotesAccessibilityID.audioPlayerTranscript)
        .onAppear(perform: loadTranscript)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            loadTranscript()
        }
    }

    private func segmentList(_ transcript: TranscriptData) -> some View {
        let currentIndex = Self.segmentIndex(at: recorderVM.playingTime, in: transcript.segments)
        let currentID = currentIndex.map { transcript.segments[$0].id }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Transcript")
                        .font(.headline)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(transcript.segments) { segment in
                        segmentRow(segment, in: transcript, isCurrent: segment.id == currentID)
                            .id(segment.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .onChange(of: currentID) { _, id in
                // Follow playback, but leave the user's scroll alone while paused.
                guard let id, recorderVM.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment, in transcript: TranscriptData, isCurrent: Bool) -> some View {
        let speaker = transcript.speakerMappings[segment.speaker] ?? segment.speaker
        let text = transcript.selectedRepresentation == .cleaned
            ? (segment.cleanup?.normalizedText ?? segment.text)
            : segment.text

        return Button {
            recorderVM.seekToTime(segment.startTime)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.timeLabel(segment.startTime))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    if !speaker.isEmpty {
                        Text(speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                isCurrent ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speaker.isEmpty ? Self.timeLabel(segment.startTime) : "\(speaker), \(Self.timeLabel(segment.startTime))")
        .accessibilityValue(text)
        .accessibilityHint("Plays the recording from here.")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func loadTranscript() {
        guard let recordingId = appCoordinator.getRecording(url: recordingURL)?.id else {
            transcript = nil
            return
        }
        transcript = appCoordinator.getTranscriptData(for: recordingId)
    }

    /// The segment playing at `time`: the last one that has started. Before the
    /// first segment nothing is current.
    static func segmentIndex(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        segments.lastIndex { $0.startTime <= time }
    }

    static func timeLabel(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
