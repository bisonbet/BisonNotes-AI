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

struct WatchRecordingView: View {
    @StateObject private var viewModel = WatchRecordingViewModel()
    @State private var showingErrorAlert = false
    @State private var recordButtonPressed = false
    @State private var pauseButtonPressed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                headerView

                recordingTimerView

                if viewModel.isTransferringAudio {
                    audioTransferView
                }

                bottomControlsView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .navigationTitle("BisonNotes AI")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("BisonNotes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(viewModel.recordingStateDescription)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(timerColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            topStatusBar
        }
        .watchCardPadding()
        .watchCardBackground()
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(spacing: 4) {
            Image(systemName: batteryIcon)
                .foregroundColor(batteryColor)
                .font(.system(size: 11, weight: .semibold))
                .scaleEffect(viewModel.batteryLevel <= 0.10 ? 1.14 : 1.0)
                .animation(
                    viewModel.batteryLevel <= 0.10 ?
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true) :
                    .easeInOut(duration: 0.3),
                    value: viewModel.batteryLevel <= 0.10
                )

            Text(viewModel.formattedBatteryLevel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(batteryColor)
                .animation(.easeInOut(duration: 0.3), value: batteryColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08), in: Capsule())
    }


    private var batteryIcon: String {
        let level = viewModel.batteryLevel
        if level > 0.75 {
            return "battery.100"
        } else if level > 0.50 {
            return "battery.75"
        } else if level > 0.25 {
            return "battery.25"
        } else {
            return "battery.0"
        }
    }

    private var batteryColor: Color {
        let level = viewModel.batteryLevel
        if level > 0.20 {
            return .primary
        } else if level > 0.10 {
            return .orange
        } else {
            return .red
        }
    }

    // MARK: - Recording Timer View

    private var recordingTimerView: some View {
        VStack(spacing: 8) {
            Text(viewModel.formattedRecordingTime)
                .font(.system(size: 31, weight: .bold, design: .monospaced))
                .foregroundColor(timerColor)
                .scaleEffect(viewModel.recordingState == .recording ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)

            HStack(spacing: 6) {
                Circle()
                    .fill(timerColor)
                    .frame(width: 6, height: 6)
                    .opacity(viewModel.recordingState == .recording ? 1.0 : 0.6)
                    .scaleEffect(viewModel.recordingState == .recording ? 1.2 : 1.0)
                    .animation(
                        viewModel.recordingState == .recording ?
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true) :
                        .easeInOut(duration: 0.3),
                        value: viewModel.recordingState
                    )

                Text(viewModel.recordingStateDescription)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .watchCardPadding()
        .watchCardBackground()
    }

    private var timerColor: Color {
        switch viewModel.recordingState {
        case .recording:
            return .red
        case .paused:
            return .orange
        case .processing:
            return .blue
        case .error:
            return .red
        default:
            return .primary
        }
    }

    // MARK: - Bottom Controls View

    private var bottomControlsView: some View {
        HStack(spacing: 12) {
            recordButton

            pauseButton
        }
        .watchCardPadding()
        .watchCardBackground()
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: recordButtonAction) {
            ZStack {
                if viewModel.recordingState == .recording {
                    Circle()
                        .fill(recordButtonColor.opacity(0.18))
                        .frame(width: 72, height: 72)
                        .scaleEffect(1.08)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: viewModel.recordingState)
                }

                Circle()
                    .fill(recordButtonColor.opacity(recordButtonEnabled ? 1.0 : 0.45))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 2)
                    )

                if viewModel.recordingState.isRecordingSession {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .scaleEffect(viewModel.recordingState == .recording ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .scaleEffect(viewModel.canStartRecording ? 1.0 : 0.8)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.canStartRecording)
                }
            }
        }
        .disabled(!recordButtonEnabled)
        .buttonStyle(.plain)
        .opacity(recordButtonEnabled ? 1.0 : 0.6)
        .scaleEffect(viewModel.recordingState == .recording ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordingState)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.recordingState)
        .accessibilityLabel(viewModel.recordingState.isRecordingSession ? "Stop Recording" : "Start Recording")
    }

    private var recordButtonColor: Color {
        switch viewModel.recordingState {
        case .idle:
            return viewModel.canStartRecording ? .red : .gray
        case .recording:
            return .red
        case .paused:
            return .red
        case .stopping, .processing:
            return .orange
        case .error:
            return .red
        }
    }

    private var recordButtonEnabled: Bool {
        switch viewModel.recordingState {
        case .idle:
            return viewModel.canStartRecording
        case .recording, .paused:
            return viewModel.canStopRecording
        case .stopping, .processing:
            return false
        case .error:
            return true // Allow retry
        }
    }

    private func recordButtonAction() {
        switch viewModel.recordingState {
        case .idle, .error:
            viewModel.startRecording()
        case .recording, .paused:
            viewModel.stopRecording()
        case .stopping, .processing:
            break // Disabled
        }
    }

    // MARK: - Pause Button

    private var pauseButton: some View {
        Button(action: pauseButtonAction) {
            ZStack {
                if pauseButtonEnabled {
                    Circle()
                        .fill(pauseButtonColor.opacity(0.16))
                        .frame(width: 58, height: 58)
                        .scaleEffect(viewModel.recordingState == .paused ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: viewModel.recordingState == .paused)
                }

                Circle()
                    .fill(pauseButtonColor.opacity(pauseButtonEnabled ? 1.0 : 0.35))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.75), lineWidth: 2)
                    )

                Image(systemName: pauseButtonIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(pauseButtonEnabled ? 1.0 : 0.8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pauseButtonEnabled)
            }
        }
        .disabled(!pauseButtonEnabled)
        .buttonStyle(.plain)
        .opacity(pauseButtonEnabled ? 1.0 : 0.3)
        .scaleEffect(pauseButtonEnabled ? 1.0 : 0.9)
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordingState)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: pauseButtonEnabled)
        .accessibilityLabel(viewModel.recordingState == .paused ? "Resume Recording" : "Pause Recording")
    }

    private var pauseButtonIcon: String {
        switch viewModel.recordingState {
        case .recording:
            return "pause.fill"
        case .paused:
            return "play.fill"
        default:
            return "pause.fill"
        }
    }

    private var pauseButtonColor: Color {
        switch viewModel.recordingState {
        case .recording:
            return .orange
        case .paused:
            return .green
        default:
            return .gray
        }
    }

    private var pauseButtonEnabled: Bool {
        return viewModel.canPauseRecording || viewModel.canResumeRecording
    }

    private func pauseButtonAction() {
        if viewModel.canPauseRecording {
            viewModel.pauseRecording()
        } else if viewModel.canResumeRecording {
            viewModel.resumeRecording()
        }
    }

    // MARK: - Audio Transfer View

    private var audioTransferView: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .scaleEffect(1.1)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.isTransferringAudio)

                VStack(alignment: .leading, spacing: 1) {
                    Text(transferStatusText)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .fontWeight(.medium)

                    if viewModel.transferProgress < 1.0 {
                        Text("Keep screen active for faster transfer")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .opacity(0.9)
                    }
                }

                Spacer()

                Text("\(Int(viewModel.transferProgress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .fontWeight(.bold)
            }

            ProgressView(value: viewModel.transferProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                .scaleEffect(y: 1.2)
                .animation(.easeInOut(duration: 0.5), value: viewModel.transferProgress)
        }
        .watchCardPadding()
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .transition(.scale.combined(with: .opacity))
    }

    /// Dynamic transfer status text based on real file transfer progress
    private var transferStatusText: String {
        if viewModel.transferProgress < 1.0 {
            return "Transferring file..."
        } else {
            return "Processing on iPhone..."
        }
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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.red)
                        .scaleEffect(1.2)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.recordingState == .error)

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
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.82))
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .scaleEffect(viewModel.recordingState == .error ? 1.0 : 0.8)
                .opacity(viewModel.recordingState == .error ? 1.0 : 0.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.recordingState == .error)
            }
            .transition(.opacity)
        }
    }
}

private extension View {
    func watchCardPadding() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    func watchCardBackground() -> some View {
        background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Preview

#if DEBUG
struct WatchRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Idle State
            WatchRecordingView()
                .previewDisplayName("Idle")

            // Recording State
            WatchRecordingView()
                .previewDisplayName("Recording")
                .environmentObject({
                    let vm = WatchRecordingViewModel.preview
                    vm.recordingState = .recording
                    vm.recordingTime = 45
                    return vm
                }())

            // Paused State
            WatchRecordingView()
                .previewDisplayName("Paused")
                .environmentObject({
                    let vm = WatchRecordingViewModel.preview
                    vm.recordingState = .paused
                    vm.recordingTime = 30
                    return vm
                }())
        }
    }
}
#endif
