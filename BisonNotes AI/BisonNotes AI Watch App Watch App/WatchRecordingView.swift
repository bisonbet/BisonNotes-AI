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
        VStack(spacing: 12) {
            // Top status bar: Battery + Phone connection
            topStatusBar
            
            Spacer()
            
            // Recording Timer (center)
            recordingTimerView
            
            // Audio Transfer Progress (only shown when transferring)
            if viewModel.isTransferringAudio {
                audioTransferView
                    .padding(.top, 8)
            }
            
            // Phone App Activation Progress (only shown when activating)
            if viewModel.isActivatingPhoneApp {
                phoneActivationView
                    .padding(.top, 8)
            }
            
            Spacer()
            
            // Bottom controls: Record + Pause buttons
            bottomControlsView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .navigationTitle("BisonNotes AI")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
        .alert("iPhone App", isPresented: $viewModel.showingActivationAlert) {
            if viewModel.activationFailed {
                Button("Open iPhone App") {
                    // Instructions for user to manually open app
                    viewModel.dismissActivationAlert()
                }
                Button("Cancel") {
                    viewModel.dismissActivationAlert()
                }
            } else {
                Button("Cancel") {
                    viewModel.dismissActivationAlert()
                }
            }
        } message: {
            if viewModel.activationFailed {
                Text("\(viewModel.activationStatusMessage)\n\nPlease open the BisonNotes AI app on your iPhone manually, then try recording again.")
            } else {
                Text(viewModel.activationStatusMessage)
            }
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
    
    // MARK: - Top Status Bar
    
    private var topStatusBar: some View {
        HStack {
            // Battery level with low battery animation
            HStack(spacing: 4) {
                Image(systemName: batteryIcon)
                    .foregroundColor(batteryColor)
                    .font(.system(size: 14))
                    .scaleEffect(viewModel.batteryLevel <= 0.10 ? 1.2 : 1.0)
                    .animation(
                        viewModel.batteryLevel <= 0.10 ? 
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : 
                        .easeInOut(duration: 0.3),
                        value: viewModel.batteryLevel <= 0.10
                    )
                
                Text(viewModel.formattedBatteryLevel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(batteryColor)
                    .animation(.easeInOut(duration: 0.3), value: batteryColor)
            }
            
            Spacer()
            
            // Phone connection status with connection animation
            Image(systemName: phoneConnectionIcon)
                .foregroundColor(phoneConnectionColor)
                .font(.system(size: 16, weight: .medium))
                .scaleEffect(viewModel.connectionState == .connecting ? 1.1 : 1.0)
                .opacity(viewModel.connectionState == .connecting ? 0.7 : 1.0)
                .animation(
                    viewModel.connectionState == .connecting ? 
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : 
                    .easeInOut(duration: 0.3),
                    value: viewModel.connectionState
                )
        }
    }
    
    private var phoneConnectionIcon: String {
        return viewModel.isPhoneAppActive && viewModel.connectionState.isConnected ? "iphone" : "iphone.slash"
    }
    
    private var phoneConnectionColor: Color {
        return viewModel.isPhoneAppActive && viewModel.connectionState.isConnected ? .green : .red
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
        VStack(spacing: 4) {
            Text(viewModel.formattedRecordingTime)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(timerColor)
                .scaleEffect(viewModel.recordingState == .recording ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)
            
            HStack(spacing: 4) {
                // Recording state indicator dot
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)
            }
        }
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
        HStack(spacing: 20) {
            // Traditional record/stop button
            recordButton
            
            // Pause/resume button (always visible)
            pauseButton
        }
    }
    
    // MARK: - Record Button
    
    private var recordButton: some View {
        Button(action: recordButtonAction) {
            ZStack {
                // Outer glow effect when recording
                if viewModel.recordingState == .recording {
                    Circle()
                        .fill(recordButtonColor.opacity(0.3))
                        .frame(width: 80, height: 80)
                        .scaleEffect(1.2)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: viewModel.recordingState)
                }
                
                Circle()
                    .fill(recordButtonColor)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                
                if viewModel.recordingState.isRecordingSession {
                    // Stop icon (square) with animation
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .scaleEffect(viewModel.recordingState == .recording ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.recordingState)
                } else {
                    // Record dot with subtle pulse
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .scaleEffect(viewModel.canStartRecording ? 1.0 : 0.8)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.canStartRecording)
                }
            }
        }
        .disabled(!recordButtonEnabled)
        .opacity(recordButtonEnabled ? 1.0 : 0.6)
        .scaleEffect(viewModel.recordingState == .recording ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordingState)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.recordingState)
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
        // Disable during phone app activation
        guard !viewModel.isActivatingPhoneApp else { return false }
        
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
                // Subtle glow when active
                if pauseButtonEnabled {
                    Circle()
                        .fill(pauseButtonColor.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .scaleEffect(viewModel.recordingState == .paused ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: viewModel.recordingState == .paused)
                }
                
                Circle()
                    .fill(pauseButtonColor)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                
                Image(systemName: pauseButtonIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(pauseButtonEnabled ? 1.0 : 0.8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pauseButtonEnabled)
            }
        }
        .disabled(!pauseButtonEnabled)
        .opacity(pauseButtonEnabled ? 1.0 : 0.3)
        .scaleEffect(pauseButtonEnabled ? 1.0 : 0.9)
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordingState)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: pauseButtonEnabled)
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
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                    .scaleEffect(1.1)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.isTransferringAudio)
                
                Text("Transferring to iPhone...")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .opacity(0.8)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: viewModel.isTransferringAudio)
                
                Spacer()
                
                Text("\(Int(viewModel.transferProgress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .fontWeight(.medium)
            }
            
            ProgressView(value: viewModel.transferProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                .scaleEffect(y: 1.0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.transferProgress)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .transition(.scale.combined(with: .opacity))
    }
    
    private var phoneActivationView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "iphone.and.arrow.right.outward")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .scaleEffect(1.1)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.isActivatingPhoneApp)
                
                Text("Activating iPhone app...")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .opacity(0.8)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: viewModel.isActivatingPhoneApp)
                
                Spacer()
            }
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                .scaleEffect(0.8)
                .animation(.easeInOut(duration: 0.3), value: viewModel.isActivatingPhoneApp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .transition(.scale.combined(with: .opacity))
    }
    
    private var audioLevelView: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "mic")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Text("Audio Level")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            
            ProgressView(value: viewModel.audioLevel)
                .progressViewStyle(LinearProgressViewStyle(tint: audioLevelColor))
                .scaleEffect(y: 0.6)
        }
    }
    
    private var audioLevelColor: Color {
        let level = viewModel.audioLevel
        if level > 0.7 {
            return .red
        } else if level > 0.4 {
            return .orange
        } else {
            return .green
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
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red)
                    )
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.2))
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                )
                .scaleEffect(viewModel.recordingState == .error ? 1.0 : 0.8)
                .opacity(viewModel.recordingState == .error ? 1.0 : 0.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.recordingState == .error)
            }
            .transition(.opacity)
        }
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