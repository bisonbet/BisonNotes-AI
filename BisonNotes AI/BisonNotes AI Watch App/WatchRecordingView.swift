//
//  WatchRecordingView.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import SwiftUI

#if canImport(WatchKit)
import WatchKit
#endif

// MARK: - Theme

private enum WatchTheme {
    /// Brand blue, defined once in AccentColor.colorset (#4A7BC4 - brightened
    /// from the bison's suit/horn navy so it reads on black)
    static let accent = Color.accentColor
    /// Dark disc fill for the idle circle on a black background
    static let circleFillIdle = Color(white: 0.12)
    /// Text/icon tone sitting on the blue disc
    static let onAccent = Color.white
}

// MARK: - Recording View

@MainActor
struct WatchRecordingView: View {
    @StateObject private var viewModel: WatchRecordingViewModel
    @State private var showingErrorAlert = false

    init() {
        _viewModel = StateObject(wrappedValue: WatchRecordingViewModel())
    }

    /// Inject a preconfigured view model (used by previews)
    init(viewModel: WatchRecordingViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    // Center: the one big button
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)

                        recorderCircle(diameter: min(geo.size.width, geo.size.height) * 0.62)

                        if viewModel.recordingState == .idle {
                            Text("Tap to Start")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Bottom corners: status chips and mute
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            bottomLeadingStatus
                            Spacer(minLength: 4)
                            if viewModel.recordingState.isRecordingSession {
                                muteButton
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                }
                .animation(.easeInOut(duration: 0.25), value: viewModel.recordingState)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isTransferringAudio)
            }
            .navigationTitle {
                Text("BisonNotes")
                    .foregroundStyle(WatchTheme.accent)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
        .overlay(
            errorStateOverlay,
            alignment: .center
        )
        .onChange(of: viewModel.showingError) { _, newValue in
            showingErrorAlert = newValue
        }
        .onAppear {
            viewModel.syncWithPhone()
        }
    }

    // MARK: - Recorder Circle

    private func recorderCircle(diameter: CGFloat) -> some View {
        Button(action: circleTapped) {
            ZStack {
                if viewModel.recordingState == .recording {
                    PulsingRings(diameter: diameter)
                        .transition(.opacity)
                }

                Circle()
                    .fill(circleFill)
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        if viewModel.recordingState == .idle || viewModel.recordingState == .error {
                            Circle()
                                .strokeBorder(
                                    WatchTheme.accent,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                                )
                        }
                    }

                circleContent(diameter: diameter)
            }
        }
        .buttonStyle(.plain)
        .disabled(circleDisabled)
        .opacity(circleDisabled ? 0.55 : 1.0)
        .accessibilityLabel(circleAccessibilityLabel)
    }

    private var circleFill: Color {
        switch viewModel.recordingState {
        case .idle, .error:
            return WatchTheme.circleFillIdle
        case .recording:
            return WatchTheme.accent
        case .paused, .stopping, .processing:
            return WatchTheme.accent.opacity(0.35)
        }
    }

    @ViewBuilder
    private func circleContent(diameter: CGFloat) -> some View {
        switch viewModel.recordingState {
        case .idle, .error:
            // The circular avatar IS the button face, like the watch face
            // complication; the dashed accent ring frames it
            bisonAvatar
                .frame(width: diameter * 0.93, height: diameter * 0.93)

        case .recording:
            VStack(spacing: 3) {
                bisonAvatar
                    .frame(width: diameter * 0.30, height: diameter * 0.30)

                Text("Capturing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WatchTheme.onAccent)

                Text(viewModel.formattedRecordingTime)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WatchTheme.onAccent)
            }

        case .paused:
            VStack(spacing: 3) {
                bisonAvatar
                    .frame(width: diameter * 0.30, height: diameter * 0.30)
                    .opacity(0.75)

                Text("Muted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WatchTheme.onAccent.opacity(0.9))

                Text(viewModel.formattedRecordingTime)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WatchTheme.onAccent.opacity(0.9))
            }

        case .stopping, .processing:
            VStack(spacing: 6) {
                ProgressView()
                    .tint(.white)

                Text("Saving…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }

    private var bisonAvatar: some View {
        Image("BisonHeadAvatar")
            .resizable()
            .scaledToFit()
            .clipShape(Circle())
    }

    private var circleDisabled: Bool {
        switch viewModel.recordingState {
        case .stopping, .processing:
            return true
        case .idle:
            return !viewModel.canStartRecording
        case .recording, .paused, .error:
            return false
        }
    }

    private var circleAccessibilityLabel: String {
        switch viewModel.recordingState {
        case .idle, .error:
            return "Start Recording"
        case .recording, .paused:
            return "Stop and Save Recording"
        case .stopping, .processing:
            return "Saving Recording"
        }
    }

    private func circleTapped() {
        switch viewModel.recordingState {
        case .idle, .error:
            viewModel.startRecording()
        case .recording, .paused:
            viewModel.stopRecording()
        case .stopping, .processing:
            break // Disabled
        }
    }

    // MARK: - Mute Button

    private var muteButton: some View {
        Button {
            if viewModel.canPauseRecording {
                viewModel.pauseRecording()
            } else if viewModel.canResumeRecording {
                viewModel.resumeRecording()
            }
        } label: {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(viewModel.recordingState == .paused ? WatchTheme.onAccent : WatchTheme.accent)
                .frame(width: 38, height: 38)
                .background(
                    viewModel.recordingState == .paused
                        ? AnyShapeStyle(WatchTheme.accent)
                        : AnyShapeStyle(Color.white.opacity(0.12)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.recordingState == .paused ? "Unmute" : "Mute")
    }

    // MARK: - Bottom Leading Status Chips

    @ViewBuilder
    private var bottomLeadingStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.isTransferringAudio {
                transferChip
                    .transition(.opacity)
            }

            if showLowBatteryChip {
                lowBatteryChip
                    .transition(.opacity)
            }
        }
    }

    private var transferChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)

            ProgressView(value: viewModel.transferProgress)
                .tint(WatchTheme.accent)
                .frame(width: 30)

            Text("\(Int(viewModel.transferProgress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(WatchTheme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    private var showLowBatteryChip: Bool {
        // -1 means the system hasn't reported a level yet
        viewModel.batteryLevel >= 0 && viewModel.batteryLevel <= 0.20
    }

    private var lowBatteryChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.25")
                .font(.system(size: 10, weight: .semibold))

            Text(viewModel.formattedBatteryLevel)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(viewModel.batteryLevel <= 0.10 ? Color.red : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    // MARK: - Error State Overlay

    @ViewBuilder
    private var errorStateOverlay: some View {
        if viewModel.recordingState == .error {
            ZStack {
                // Background dim
                Color.black
                    .opacity(0.3)
                    .ignoresSafeArea()

                // Error card
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.red)

                    Text("Recording Error")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }

                    Button("Try Again") {
                        viewModel.dismissError()
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red)
                    )
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(WatchTheme.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Pulsing Rings

/// Concentric rings that expand and fade while capturing. Only placed in the
/// hierarchy while recording, so the repeatForever animations are torn down
/// cleanly on any state change.
private struct PulsingRings: View {
    let diameter: CGFloat
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(WatchTheme.accent.opacity(0.55), lineWidth: 2)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(animate ? 1.55 : 1.0)
                    .opacity(animate ? 0.0 : 0.6)
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.8),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#if DEBUG
struct WatchRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            WatchRecordingView()
                .previewDisplayName("Idle")

            WatchRecordingView(viewModel: {
                let vm = WatchRecordingViewModel.preview
                vm.recordingState = .recording
                vm.recordingTime = 45
                return vm
            }())
            .previewDisplayName("Capturing")

            WatchRecordingView(viewModel: {
                let vm = WatchRecordingViewModel.preview
                vm.recordingState = .paused
                vm.recordingTime = 30
                return vm
            }())
            .previewDisplayName("Muted")

            WatchRecordingView(viewModel: {
                let vm = WatchRecordingViewModel.preview
                vm.recordingState = .idle
                vm.isTransferringAudio = true
                vm.transferProgress = 0.6
                vm.batteryLevel = 0.15
                return vm
            }())
            .previewDisplayName("Transferring + Low Battery")
        }
    }
}
#endif
