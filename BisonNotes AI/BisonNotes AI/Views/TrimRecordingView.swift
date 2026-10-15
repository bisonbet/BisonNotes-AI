//
//  TrimRecordingView.swift
//  BisonNotes AI
//
//  Pick a start and end on an existing recording and save the clip as a new
//  recording. The original is never modified; deleting it stays the user's call.
//

import SwiftUI
import AVFoundation

struct TrimRecordingView: View {
    let recording: AudioRecordingFile

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @EnvironmentObject var recorderVM: AudioRecorderViewModel

    @State private var duration: TimeInterval = 0
    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    @State private var loadError: String?

    @State private var existingWorkWarning: String?
    @State private var verificationFailed = false

    @State private var isTrimming = false
    @State private var errorMessage: String?
    @State private var savedRecordingName: String?
    @State private var postCommitWarning: String?

    @State private var isScanning = false
    @State private var scanProgress: Double = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var scanOutcome: TrailingSilenceScanOutcome?

    @State private var previewToken: UUID?
    @State private var previewingEdge: RecordingTrimMath.Edge?

    /// How much audio an edge preview plays.
    private let previewLength: TimeInterval = 4

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    content
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trim Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { close() }
                        .disabled(isTrimming)
                        .accessibilityIdentifier("bisonnotes.trim.cancel")
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
            .alert("Trimmed Recording Saved", isPresented: Binding(
                get: { savedRecordingName != nil },
                set: { if !$0 { savedRecordingName = nil } }
            )) {
                Button("Done") { close() }
            } message: {
                Text(savedMessage)
            }
            .task { await loadSource() }
            .onDisappear {
                scanTask?.cancel()
                stopPreview()
            }
        }
        .interactiveDismissDisabled(isTrimming)
#if os(macOS)
        .nativeMacPresentationContext(.modalSheet)
        .onExitCommand {
            guard !isTrimming else { return }
            close()
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        if verificationFailed {
            blockingSection
        } else if let loadError {
            noticeCard(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Cannot Trim This Recording",
                message: loadError
            )
        } else if duration <= 0 {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading audio…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            if let existingWorkWarning {
                noticeCard(
                    icon: "info.circle.fill",
                    tint: .orange,
                    title: "Transcripts and summaries are not carried over",
                    message: existingWorkWarning
                )
            }
            rangeSection
            edgeSection(.start)
            edgeSection(.end)
            silenceSection
            resultSection
            trimButton
        }
    }

    private var savedMessage: String {
        var message = "\"\(savedRecordingName ?? "")\" was added to your recordings. "
            + "The original recording is unchanged; delete it from the recordings list if you no longer need it."
        if let postCommitWarning {
            message += "\n\n" + postCommitWarning
        }
        return message
    }

    // MARK: Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "scissors")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(recording.name)
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(2)

            Text("Choose the part to keep. It is saved as a new recording; the original is not changed.")
                .font(.body)
                .foregroundColor(.secondary)
        }
    }

    private var blockingSection: some View {
        noticeCard(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            title: "Cannot Trim Recording",
            message: "Could not verify this recording in storage before trimming. Close this sheet and try again."
        )
    }

    private func noticeCard(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.1)))
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RecordingTrimMath.formatEdge(start))
                Spacer()
                Text("Keeping \(RecordingTrimMath.formatEdge(end - start))")
                    .foregroundColor(.secondary)
                Spacer()
                Text(RecordingTrimMath.formatEdge(end))
            }
            .font(.caption)
            .monospacedDigit()

            TrimRangeSlider(
                start: $start,
                end: $end,
                duration: duration,
                playhead: previewingEdge != nil ? recorderVM.playingTime : nil,
                suggestedEnd: suggestedEnd
            )
            .frame(height: 44)
            .disabled(isTrimming)
            .onChange(of: start) { _, _ in stopPreview() }
            .onChange(of: end) { _, _ in stopPreview() }

            HStack {
                Text("0:00").foregroundColor(.secondary)
                Spacer()
                Text(RecordingTrimMath.formatEdge(duration)).foregroundColor(.secondary)
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func edgeSection(_ edge: RecordingTrimMath.Edge) -> some View {
        let isStart = edge == .start
        let value = isStart ? start : end
        let isPreviewing = previewingEdge == edge

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isStart ? "Start" : "End")
                    .font(.headline)
                Spacer()
                Text(RecordingTrimMath.formatEdge(value))
                    .font(.body.monospacedDigit())
                    .fontWeight(.semibold)
                    .accessibilityLabel("\(isStart ? "Start" : "End") time \(RecordingTrimMath.formatEdge(value))")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nudgeButtons(edge)
                    Spacer(minLength: 8)
                    previewButton(edge, isPreviewing: isPreviewing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { nudgeButtons(edge) }
                    previewButton(edge, isPreviewing: isPreviewing)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func nudgeButtons(_ edge: RecordingTrimMath.Edge) -> some View {
        ForEach([-10.0, -1.0, 1.0, 10.0], id: \.self) { step in
            Button(step < 0 ? "\(Int(step))s" : "+\(Int(step))s") {
                nudge(edge, by: step)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .monospacedDigit()
            .disabled(isTrimming)
            .accessibilityLabel("Move \(edge == .start ? "start" : "end") \(step < 0 ? "back" : "forward") \(Int(abs(step))) seconds")
        }
    }

    private func previewButton(_ edge: RecordingTrimMath.Edge, isPreviewing: Bool) -> some View {
        Button {
            if isPreviewing {
                stopPreview()
            } else {
                preview(edge)
            }
        } label: {
            Label(
                isPreviewing ? "Stop" : (edge == .start ? "Play from Start" : "Play to End"),
                systemImage: isPreviewing ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isTrimming)
        .accessibilityHint(edge == .start
            ? "Plays the first few seconds that will be kept."
            : "Plays the last few seconds that will be kept.")
    }

    private var suggestedEnd: TimeInterval? {
        if case .suggestion(let suggestion) = scanOutcome { return suggestion.suggestedEnd }
        return nil
    }

    private var silenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trim Trailing Silence")
                .font(.headline)
            Text("Scans backwards from the end for the last speech and suggests an end point. Nothing changes until you use the suggestion.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isScanning {
                HStack(spacing: 10) {
                    ProgressView(value: scanProgress)
                    Button("Stop") { scanTask?.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                switch scanOutcome {
                case .suggestion(let suggestion):
                    Text("Speech appears to end near \(RecordingTrimMath.formatEdge(suggestion.lastActivityEnd)), "
                        + "followed by \(RecordingTrimMath.formatEdge(suggestion.trailingSilence)) of silence.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Use Suggested End (\(RecordingTrimMath.formatEdge(suggestion.suggestedEnd)))") {
                            applySuggestion(suggestion)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isTrimming)
                        Button("Scan Again") { startScan() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                case .noTrailingSilence:
                    Text("No trailing silence found — audio continues to the end.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                case .entirelySilent:
                    Text("No speech was detected anywhere in this recording.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                case nil:
                    Button {
                        startScan()
                    } label: {
                        Label("Find Trailing Silence", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTrimming)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Original length", RecordingTrimMath.formatEdge(duration))
            row("New recording", RecordingTrimMath.formatEdge(end - start))
            row("Removed", RecordingTrimMath.formatEdge(max(0, duration - (end - start))))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.body)
    }

    private var canTrim: Bool {
        !isTrimming && RecordingTrimMath.isValid(start: start, end: end, duration: duration)
    }

    private var trimButton: some View {
        Button {
            Task { await trim() }
        } label: {
            HStack {
                if isTrimming {
                    ProgressView().scaleEffect(0.8).tint(.white)
                    Text("Saving Trimmed Recording…")
                } else {
                    Image(systemName: "scissors")
                    Text("Save as New Recording")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(canTrim ? Color.blue : Color.gray))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canTrim)
        .accessibilityIdentifier("bisonnotes.trim.save")
    }

    // MARK: Actions

    private func close() {
        scanTask?.cancel()
        stopPreview()
        dismiss()
    }

    private func nudge(_ edge: RecordingTrimMath.Edge, by step: TimeInterval) {
        let proposed = edge == .start
            ? RecordingTrimMath.clamped(start: start + step, end: end, duration: duration, moving: .start)
            : RecordingTrimMath.clamped(start: start, end: end + step, duration: duration, moving: .end)
        start = proposed.start
        end = proposed.end
    }

    private func applySuggestion(_ suggestion: TrailingSilenceSuggestion) {
        let proposed = RecordingTrimMath.clamped(
            start: start, end: suggestion.suggestedEnd, duration: duration, moving: .end
        )
        start = proposed.start
        end = proposed.end
        AccessibilitySupport.announce("End moved to \(RecordingTrimMath.formatEdge(end))")
    }

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        scanProgress = 0
        scanOutcome = nil
        let url = recording.url
        scanTask = Task {
            do {
                let outcome = try await TrailingSilenceDetector.scan(fileURL: url) { fraction in
                    Task { @MainActor in scanProgress = fraction }
                }
                scanOutcome = outcome
            } catch is CancellationError {
                scanOutcome = nil
            } catch {
                errorMessage = "Could not scan for silence: \(error.localizedDescription)"
            }
            isScanning = false
        }
    }

    private func preview(_ edge: RecordingTrimMath.Edge) {
        stopPreview()
        let from = edge == .start ? start : max(start, end - previewLength)
        let length = edge == .start ? min(previewLength, end - start) : end - from
        let token = UUID()
        previewToken = token
        previewingEdge = edge
        recorderVM.playingTime = from
        recorderVM.playRecording(url: recording.url)
        Task {
            try? await Task.sleep(for: .seconds(max(0.5, length)))
            guard previewToken == token else { return }
            stopPreview()
        }
    }

    private func stopPreview() {
        guard previewToken != nil else { return }
        previewToken = nil
        previewingEdge = nil
        if recorderVM.isPlaying || recorderVM.isPreparingPlayback {
            recorderVM.stopPlaying()
        }
    }

    private func loadSource() async {
        // A preview from this sheet shares the app's player; stop anything the
        // audio player underneath was playing so the two never overlap.
        if recorderVM.isPlaying || recorderVM.isPreparingPlayback {
            recorderVM.stopPlaying()
        }
        guard verifyRecording() else { return }
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            loadError = "The audio file for this recording is not on this device. Restore it before trimming."
            return
        }
        do {
            // The export measures the source with AVURLAsset, so the handles must
            // use the same clock or a "full length" end can overshoot it.
            let seconds = try await AVURLAsset(url: recording.url).load(.duration).seconds
            guard seconds.isFinite, seconds > RecordingTrimMath.minimumClipDuration else {
                loadError = "This recording is too short to trim."
                return
            }
            duration = seconds
            start = 0
            end = seconds
        } catch {
            loadError = "This audio file could not be read: \(error.localizedDescription)"
        }
    }

    /// Confirms the row exists and notes existing transcripts and summaries.
    /// Unlike Combine this does not refuse: the original keeps its transcript
    /// and summary untouched, and the new recording simply starts without
    /// one. It does say so up front, so nobody expects the work to follow.
    @discardableResult
    private func verifyRecording() -> Bool {
        do {
            guard let entry = try fetchEntry(), let id = entry.id else {
                throw FileManagementError.relationshipNotFound
            }
            var existing: [String] = []
            if try appCoordinator.coreDataManager.fetchTranscript(for: id) != nil {
                existing.append("a transcript")
            }
            if try appCoordinator.coreDataManager.fetchSummary(for: id) != nil {
                existing.append("a summary")
            }
            existingWorkWarning = existing.isEmpty ? nil
                : "This recording has \(existing.joined(separator: " and ")). They stay with the original. "
                    + "The trimmed recording starts without them; transcribe it again if you need one."
            verificationFailed = false
            return true
        } catch {
            verificationFailed = true
            return false
        }
    }

    private func fetchEntry() throws -> RecordingEntry? {
        if let id = recording.recordingId {
            return try appCoordinator.coreDataManager.fetchRecording(id: id)
        }
        return try appCoordinator.coreDataManager.fetchRecording(url: recording.url)
    }

    private func trim() async {
        guard canTrim, verifyRecording() else { return }
        stopPreview()
        scanTask?.cancel()
        isTrimming = true
        defer { isTrimming = false }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documents.appendingPathComponent(
            "trimmed_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).m4a"
        )

        // The export lands in Documents before `addRecording` gives it a row,
        // and until then nothing references it. Claim the path so reviewed-audio
        // cleanup cannot treat a trim that is still running as a leftover.
        ActiveAudioWorkRegistry.shared.beginWriting(outputURL)
        defer { ActiveAudioWorkRegistry.shared.finishWriting(outputURL) }

        let recordingId: UUID
        let trimmedName = "\(recording.name) (trimmed)"
        let sourceIsLocalOnly: Bool
        do {
            guard let sourceEntry = try fetchEntry() else {
                throw FileManagementError.relationshipNotFound
            }
            sourceIsLocalOnly = sourceEntry.isCloudSyncDisabled
            let location = appCoordinator.coreDataManager.getLocationData(for: sourceEntry)
                ?? appCoordinator.loadLocationData(for: sourceEntry)
            let quality = sourceEntry.audioQuality.flatMap(AudioQuality.init(rawValue:)) ?? .whisperOptimized

            let result = try await RecordingTrimmer.export(
                sourceURL: recording.url,
                start: start,
                end: end,
                outputURL: outputURL
            )

            do {
                recordingId = try appCoordinator.addRecording(
                    url: result.outputURL,
                    name: trimmedName,
                    date: RecordingTrimMath.trimmedRecordingDate(sourceDate: recording.date, start: start),
                    fileSize: result.fileSize,
                    duration: result.duration,
                    quality: quality,
                    locationData: location
                )
            } catch {
                // No row points at the export, so nothing would ever clean it up.
                try? FileManager.default.removeItem(at: result.outputURL)
                throw error
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // The trimmed recording is durable from here on. Anything that fails
        // below is a loose end to report, never a failed trim.
        postCommitWarning = nil
        if sourceIsLocalOnly {
            let failure = afterCommit("Keep trimmed recording on this device", category: .recording) {
                try appCoordinator.coreDataManager.updateCloudSyncDisabled(for: recordingId, disabled: true)
            }
            if failure != nil {
                postCommitWarning = "The original is set to Keep on This Device, but that setting could not be "
                    + "copied to the trimmed recording. Turn it on from the trimmed recording's player."
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
        AccessibilitySupport.announce("Trimmed recording saved")
        savedRecordingName = trimmedName
    }
}

// MARK: - Range slider

/// A track with independent start and end handles. Drags are clamped through
/// `RecordingTrimMath.clamped`, so the handles can never cross or close below
/// the minimum clip length.
///
/// One drag gesture covers the whole track and moves whichever handle is
/// nearest where the drag began. Per-handle gestures were unreliable: the
/// handles are positioned with `.offset`, which moves the drawing but not the
/// layout frame, so their hit areas stayed parked at the leading edge.
struct TrimRangeSlider: View {
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    let duration: TimeInterval
    var playhead: TimeInterval?
    var suggestedEnd: TimeInterval?

    @Environment(\.isEnabled) private var isEnabled
    /// The handle a drag in progress is moving, chosen when the drag begins.
    @State private var activeEdge: RecordingTrimMath.Edge?

    private let handleWidth: CGFloat = 22
    private let trackHeight: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let usable = max(1, geometry.size.width - handleWidth)
            let startX = x(for: start, usable: usable)
            let endX = x(for: end, usable: usable)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: trackHeight)
                    .padding(.horizontal, handleWidth / 2)

                Rectangle()
                    .fill(Color.accentColor.opacity(isEnabled ? 0.3 : 0.15))
                    .frame(width: max(0, endX - startX), height: trackHeight)
                    .offset(x: startX + handleWidth / 2)

                if let suggestedEnd, duration > 0 {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2, height: trackHeight + 8)
                        .offset(x: x(for: suggestedEnd, usable: usable) + handleWidth / 2 - 1)
                }

                if let playhead, duration > 0 {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: trackHeight)
                        .offset(x: x(for: playhead, usable: usable) + handleWidth / 2 - 1)
                }

                handleShape(edge: .start, isActive: activeEdge == .start)
                    .offset(x: startX)
                handleShape(edge: .end, isActive: activeEdge == .end)
                    .offset(x: endX)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, duration > 0 else { return }
                        let edge = activeEdge ?? nearestEdge(
                            to: drag.startLocation.x, startX: startX, endX: endX
                        )
                        activeEdge = edge
                        move(edge, to: time(at: drag.location.x, usable: usable))
                    }
                    .onEnded { _ in activeEdge = nil }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(true)
            .overlay(alignment: .leading) {
                // Invisible, correctly placed elements so VoiceOver users can
                // adjust each edge; the visible handles carry no semantics.
                accessibilityHandle(edge: .start)
                    .offset(x: startX)
                accessibilityHandle(edge: .end)
                    .offset(x: endX)
            }
        }
    }

    private func x(for time: TimeInterval, usable: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * usable
    }

    /// The time under a point on the track. The handle's centre tracks the
    /// finger, so half a handle is taken off each end of the usable width.
    private func time(at locationX: CGFloat, usable: CGFloat) -> TimeInterval {
        let fraction = min(max((locationX - handleWidth / 2) / usable, 0), 1)
        return Double(fraction) * duration
    }

    /// The handle closest to where a drag began. When the handles overlap,
    /// a touch left of them pulls the start and right of them the end, so a
    /// collapsed range can always be reopened in either direction.
    private func nearestEdge(to locationX: CGFloat, startX: CGFloat, endX: CGFloat) -> RecordingTrimMath.Edge {
        let startCenter = startX + handleWidth / 2
        let endCenter = endX + handleWidth / 2
        if abs(endCenter - startCenter) < handleWidth {
            return locationX < (startCenter + endCenter) / 2 ? .start : .end
        }
        return abs(locationX - startCenter) <= abs(locationX - endCenter) ? .start : .end
    }

    private func handleShape(edge: RecordingTrimMath.Edge, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isEnabled ? Color.accentColor : Color.gray)
            .frame(width: handleWidth, height: trackHeight + 10)
            .overlay(
                Image(systemName: edge == .start ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.headline)
                    .foregroundColor(.white)
            )
            .scaleEffect(isActive ? 1.12 : 1)
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            .animation(.easeOut(duration: 0.1), value: isActive)
    }

    private func accessibilityHandle(edge: RecordingTrimMath.Edge) -> some View {
        let isStart = edge == .start
        let value = isStart ? start : end
        return Color.clear
            .frame(width: handleWidth, height: trackHeight + 10)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
            .accessibilityValue(RecordingTrimMath.formatEdge(value))
            .accessibilityHint("Swipe up or down to move by 5 seconds.")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 5 : -5
                move(edge, to: value + step)
            }
    }

    private func move(_ edge: RecordingTrimMath.Edge, to time: TimeInterval) {
        let proposed = edge == .start
            ? RecordingTrimMath.clamped(start: time, end: end, duration: duration, moving: .start)
            : RecordingTrimMath.clamped(start: start, end: time, duration: duration, moving: .end)
        start = proposed.start
        end = proposed.end
    }
}
