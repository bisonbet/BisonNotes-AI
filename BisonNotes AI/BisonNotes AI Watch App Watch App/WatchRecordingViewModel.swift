//
//  WatchRecordingViewModel.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import Foundation
import SwiftUI
import Combine

#if canImport(WatchKit)
import WatchKit
#endif

/// Main state manager for the watch recording app
@MainActor
class WatchRecordingViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var recordingState: WatchRecordingState = .idle
    @Published var recordingTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    @Published var batteryLevel: Float = 1.0
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isPhoneAppActive: Bool = false
    @Published var errorMessage: String?
    @Published var showingError: Bool = false
    @Published var isTransferringAudio: Bool = false
    @Published var transferProgress: Double = 0.0
    @Published var isActivatingPhoneApp: Bool = false
    @Published var showingActivationAlert: Bool = false
    @Published var activationStatusMessage: String = ""
    @Published var activationFailed: Bool = false
    
    // MARK: - Private Properties
    private let audioManager = WatchAudioManager()
    private let connectivityManager = WatchConnectivityManager.shared
    private let feedbackManager = WatchFeedbackManager()
    private var cancellables = Set<AnyCancellable>()
    private var recordingSessionId: UUID?
    private var isWatchInitiatedRecording: Bool = false
    
    // App activation tracking
    private var activationRetryCount = 0
    private let maxActivationRetries = 3
    private let activationTimeout: TimeInterval = 10.0
    
    // MARK: - Computed Properties
    
    var canStartRecording: Bool {
        return recordingState.canStartRecording && connectionState.isConnected
    }
    
    var canStopRecording: Bool {
        return recordingState.canStop
    }
    
    var canPauseRecording: Bool {
        return recordingState.canPause
    }
    
    var canResumeRecording: Bool {
        return recordingState.canResume
    }
    
    var formattedRecordingTime: String {
        return formatTime(recordingTime)
    }
    
    var formattedBatteryLevel: String {
        return "\(Int(batteryLevel * 100))%"
    }
    
    var recordingStateDescription: String {
        return recordingState.description
    }
    
    var connectionStatusDescription: String {
        return connectionState.description
    }
    
    // MARK: - Initialization
    
    init() {
        setupAudioManager()
        setupConnectivityManager()
        setupBindings()
        
        print("⌚ WatchRecordingViewModel initialized")
    }
    
    // MARK: - Setup Methods
    
    private func setupAudioManager() {
        // Set up audio manager callbacks
        audioManager.onRecordingStateChanged = { [weak self] isRecording, isPaused in
            Task { @MainActor in
                self?.handleAudioRecordingStateChanged(isRecording: isRecording, isPaused: isPaused)
            }
        }
        
        audioManager.onAudioChunkReady = { [weak self] chunk in
            Task { @MainActor in
                self?.handleAudioChunkReady(chunk)
            }
        }
        
        audioManager.onRecordingCompleted = { [weak self] chunks in
            Task { @MainActor in
                self?.handleRecordingCompleted(chunks)
            }
        }
        
        audioManager.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleAudioError(error)
            }
        }
    }
    
    private func setupConnectivityManager() {
        // Set up connectivity manager callbacks
        connectivityManager.onPhoneRecordingStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handlePhoneRecordingStateChanged(state)
            }
        }
        
        connectivityManager.onPhoneAppActivated = { [weak self] in
            Task { @MainActor in
                self?.handlePhoneAppActivated()
            }
        }
        
        connectivityManager.onPhoneErrorReceived = { [weak self] error in
            Task { @MainActor in
                self?.handlePhoneError(error)
            }
        }
        
        connectivityManager.onAudioTransferCompleted = { [weak self] success in
            Task { @MainActor in
                self?.handleAudioTransferCompleted(success)
            }
        }
    }
    
    private func setupBindings() {
        // Bind audio manager properties
        audioManager.$recordingTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingTime)
        
        audioManager.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
        
        audioManager.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLevel in
                guard let self = self else { return }
                let oldLevel = self.batteryLevel
                self.batteryLevel = newLevel
                
                // Provide feedback for low battery (only when level drops significantly)
                if oldLevel > 0.10 && newLevel <= 0.10 {
                    self.feedbackManager.feedbackForBatteryLevel(newLevel)
                }
            }
            .store(in: &cancellables)
        
        audioManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] errorMessage in
                self?.showError(errorMessage)
            }
            .store(in: &cancellables)
        
        // Bind connectivity manager properties with feedback
        connectivityManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                let oldState = self.connectionState
                self.connectionState = newState
                
                // Provide feedback for connection state changes
                self.feedbackManager.feedbackForConnectionStateChange(from: oldState, to: newState)
            }
            .store(in: &cancellables)
        
        connectivityManager.$isPhoneAppActive
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPhoneAppActive)
        
        connectivityManager.$isTransferringAudio
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTransferringAudio)
        
        connectivityManager.$audioTransferProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$transferProgress)
    }
    
    // MARK: - Public Interface
    
    /// Start recording audio and notify phone
    func startRecording() {
        guard canStartRecording else {
            showError("Cannot start recording: \(recordingState.description)")
            return
        }
        
        print("⌚ Starting recording...")
        
        // Reset activation retry count
        activationRetryCount = 0
        
        // Activate phone app if needed with proper verification
        if !isPhoneAppActive {
            activatePhoneAppWithRetry()
        } else {
            initiateRecording()
        }
    }
    
    /// Stop recording and transfer audio to phone
    func stopRecording() {
        guard canStopRecording else {
            showError("Cannot stop recording")
            return
        }
        
        print("⌚ Stopping recording...")
        let oldState = recordingState
        recordingState = .stopping
        
        // Reset watch-initiated recording flag
        isWatchInitiatedRecording = false
        
        // Stop audio recording
        audioManager.stopRecording()
        
        // Notify phone to stop
        connectivityManager.sendRecordingCommand(.stopRecording)
        
        // Provide comprehensive feedback
        feedbackManager.feedbackForRecordingStateChange(from: oldState, to: .stopping)
    }
    
    /// Pause recording
    func pauseRecording() {
        guard canPauseRecording else {
            showError("Cannot pause recording")
            return
        }
        
        print("⌚ Pausing recording...")
        
        let oldState = recordingState
        audioManager.pauseRecording()
        connectivityManager.sendRecordingCommand(.pauseRecording)
        
        // State will be updated by the audio manager callback
        feedbackManager.feedbackForRecordingStateChange(from: oldState, to: .paused)
    }
    
    /// Resume recording
    func resumeRecording() {
        guard canResumeRecording else {
            showError("Cannot resume recording")
            return
        }
        
        print("⌚ Resuming recording...")
        
        let oldState = recordingState
        audioManager.resumeRecording()
        connectivityManager.sendRecordingCommand(.resumeRecording)
        
        // State will be updated by the audio manager callback
        feedbackManager.feedbackForRecordingStateChange(from: oldState, to: .recording)
    }
    
    /// Manually sync with phone
    func syncWithPhone() {
        connectivityManager.requestSyncWithPhone()
        
        // Send current state to phone
        sendCurrentStateToPhone()
    }
    
    /// Dismiss current error
    func dismissError() {
        errorMessage = nil
        showingError = false
    }
    
    // MARK: - Private Methods
    
    /// Activate phone app with retry mechanism and verification
    private func activatePhoneAppWithRetry() {
        guard activationRetryCount < maxActivationRetries else {
            handleActivationFailure("Failed to activate iPhone app after \(maxActivationRetries) attempts")
            return
        }
        
        activationRetryCount += 1
        isActivatingPhoneApp = true
        showingActivationAlert = true
        activationFailed = false
        
        if activationRetryCount == 1 {
            activationStatusMessage = "Starting iPhone app..."
        } else {
            activationStatusMessage = "Retrying iPhone activation... (\(activationRetryCount)/\(maxActivationRetries))"
        }
        
        print("⌚ Attempting to activate iPhone app (attempt \(activationRetryCount)/\(maxActivationRetries))")
        
        // Use proper activation request
        connectivityManager.requestPhoneAppActivation()
        
        // Start a single timer for this activation attempt
        startActivationTimer()
    }
    
    /// Start a timer to check for phone activation with timeout
    private func startActivationTimer() {
        let startTime = Date()
        let _ = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, self.activationTimeout - elapsed)
            
            // Update status message with remaining time
            DispatchQueue.main.async {
                if remaining > 0 {
                    self.activationStatusMessage = "Starting iPhone app... \(Int(remaining))s"
                }
                
                if self.isPhoneAppActive {
                    // Success! Phone app is now active
                    timer.invalidate()
                    print("⌚ iPhone app activated successfully after \(String(format: "%.1f", elapsed))s")
                    self.handleActivationSuccess()
                } else if elapsed >= self.activationTimeout {
                    // Timeout reached, retry or fail
                    timer.invalidate()
                    print("⌚ iPhone app activation timeout after \(String(format: "%.1f", elapsed))s (attempt \(self.activationRetryCount))")
                    
                    if self.activationRetryCount < self.maxActivationRetries {
                        // Retry after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.activatePhoneAppWithRetry()
                        }
                    } else {
                        self.handleActivationFailure("iPhone app failed to activate")
                    }
                }
            }
            // If neither condition is met, timer continues (no infinite recursion)
        }
    }
    
    /// Handle successful iPhone app activation
    private func handleActivationSuccess() {
        isActivatingPhoneApp = false
        showingActivationAlert = false
        activationRetryCount = 0
        activationStatusMessage = "iPhone app activated!"
        
        // Show brief success message then proceed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.initiateRecording()
        }
    }
    
    /// Handle failed iPhone app activation
    private func handleActivationFailure(_ message: String) {
        isActivatingPhoneApp = false
        activationFailed = true
        activationStatusMessage = message
        
        // Keep the alert showing with failure message and instructions
        // User can manually dismiss or try opening iPhone app manually
    }
    
    /// Dismiss activation alert
    func dismissActivationAlert() {
        showingActivationAlert = false
        activationFailed = false
        activationStatusMessage = ""
    }
    
    private func initiateRecording() {
        // Mark this as a watch-initiated recording
        isWatchInitiatedRecording = true
        
        // Start local audio recording
        guard audioManager.startRecording() else {
            showError("Failed to start audio recording")
            isWatchInitiatedRecording = false
            return
        }
        
        // Generate session ID
        recordingSessionId = audioManager.getCurrentSessionId()
        
        // Notify phone to start recording
        connectivityManager.sendRecordingCommand(.startRecording, additionalInfo: [
            "sessionId": recordingSessionId?.uuidString ?? ""
        ])
        
        let oldState = recordingState
        recordingState = .recording
        
        // Provide comprehensive feedback
        feedbackManager.feedbackForRecordingStateChange(from: oldState, to: .recording)
        
        print("⌚ Recording initiated with session ID: \(recordingSessionId?.uuidString ?? "unknown")")
    }
    
    private func sendCurrentStateToPhone() {
        connectivityManager.sendRecordingStatusToPhone(
            recordingState,
            recordingTime: recordingTime,
            error: errorMessage
        )
    }
    
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
        
        // Auto-dismiss error after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if self.errorMessage == message {
                self.dismissError()
            }
        }
        
        // Provide haptic feedback for errors
        #if canImport(WatchKit)
        WKInterfaceDevice.current().play(.failure)
        #endif
        
        print("⌚ Error: \(message)")
    }
    
    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Event Handlers
    
    private func handleAudioRecordingStateChanged(isRecording: Bool, isPaused: Bool) {
        if isRecording && isPaused {
            recordingState = .paused
        } else if isRecording {
            recordingState = .recording
        } else {
            recordingState = .idle
        }
        
        // Send state update to phone
        sendCurrentStateToPhone()
        
        print("⌚ Audio recording state changed: \(recordingState.rawValue)")
    }
    
    private func handleAudioChunkReady(_ chunk: WatchAudioChunk) {
        // Transfer chunk to phone using robust retry mechanism
        connectivityManager.transferSingleChunk(chunk) { [weak self] success, error in
            guard let self = self else { return }
            
            if success {
                print("⌚ Audio chunk \(chunk.sequenceNumber) transferred successfully")
                // Mark chunk as successfully transferred in audio manager
                self.audioManager.markChunkTransferred(chunk)
            } else {
                if let error = error {
                    print("⚠️ Audio chunk \(chunk.sequenceNumber) transfer failed: \(error.localizedDescription)")
                    // Buffer the chunk for retry via audio manager's retry system
                    self.audioManager.handleChunkTransferFailure(chunk, error: error)
                } else {
                    let unknownError = WatchAudioError.transferFailed("Unknown transfer error")
                    print("⚠️ Audio chunk \(chunk.sequenceNumber) transfer failed: Unknown error")
                    self.audioManager.handleChunkTransferFailure(chunk, error: unknownError)
                }
            }
        }
        
        print("⌚ Audio chunk \(chunk.sequenceNumber) queued for transfer")
    }
    
    private func handleRecordingCompleted(_ chunks: [WatchAudioChunk]) {
        print("⌚ Recording completed with \(chunks.count) chunks")
        
        // With real-time chunking, most chunks have already been transferred
        // Only need to ensure the final chunk was sent and mark recording as complete
        recordingState = .processing
        
        // Send completion signal to phone
        connectivityManager.sendRecordingCommand(.audioTransferComplete, additionalInfo: [
            "sessionId": recordingSessionId?.uuidString ?? "",
            "totalChunks": chunks.count,
            "completedAt": Date().timeIntervalSince1970
        ])
        
        // Recording is effectively complete - chunks were transferred in real-time
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.recordingState = .idle
            self.recordingSessionId = nil
        }
        
        print("⌚ Real-time recording transfer completed")
    }
    
    private func handleAudioError(_ error: WatchAudioError) {
        recordingState = .error
        showError(error.localizedDescription)
        
        // Notify phone of error
        let watchError = WatchErrorMessage(
            errorType: .audioRecordingFailed,
            message: error.localizedDescription,
            deviceType: .appleWatch
        )
        connectivityManager.onPhoneErrorReceived?(watchError)
    }
    
    private func handlePhoneRecordingStateChanged(_ state: WatchRecordingState) {
        print("⌚ Phone recording state changed: \(state.rawValue)")
        
        // Don't stop watch recording if it was initiated by the watch
        // Only sync states for phone-initiated recordings
        if isWatchInitiatedRecording && recordingState.isRecordingSession {
            print("⌚ Ignoring phone state change - watch-initiated recording in progress")
            return
        }
        
        // For phone-initiated state changes, only sync if watch is in a compatible state
        if recordingState != state {
            switch state {
            case .idle:
                // Always sync to idle state to reset everything
                if recordingState.isRecordingSession {
                    stopRecording()
                } else {
                    recordingState = .idle
                }
                
            case .recording:
                // Only sync to recording state if watch is currently idle
                // Don't try to sync to recording state if watch isn't actually recording
                if recordingState == .idle {
                    print("⌚ Phone started recording, but watch won't sync recording state without actual audio recording")
                    // Just acknowledge the phone state but keep watch idle
                    // The user can manually start recording on watch if they want to join
                }
                
            case .paused:
                if recordingState == .recording {
                    pauseRecording()
                }
                
            default:
                // For other states (processing, stopping, error), just update the UI state
                recordingState = state
            }
        }
    }
    
    private func handlePhoneAppActivated() {
        print("⌚ Phone app activated")
        isPhoneAppActive = true
        
        // If we were trying to activate, mark as successful
        if isActivatingPhoneApp {
            handleActivationSuccess()
        }
        
        // Send current state to newly activated phone app
        sendCurrentStateToPhone()
    }
    
    private func handlePhoneError(_ error: WatchErrorMessage) {
        showError("Phone: \(error.message)")
    }
    
    private func handleAudioTransferCompleted(_ success: Bool) {
        isTransferringAudio = false
        transferProgress = 0.0
        
        // Reset watch-initiated recording flag when transfer completes
        isWatchInitiatedRecording = false
        
        if success {
            print("⌚ Audio transfer completed successfully")
            recordingState = .idle
            
            // Provide success feedback
            feedbackManager.feedbackForTransferProgress(completed: true)
        } else {
            print("⌚ Audio transfer failed")
            showError("Failed to transfer audio to phone")
            recordingState = .error
            
            // Provide failure feedback
            feedbackManager.feedbackForTransferProgress(completed: false, failed: true)
        }
    }
}

// MARK: - Preview Support

#if DEBUG
extension WatchRecordingViewModel {
    static var preview: WatchRecordingViewModel {
        let viewModel = WatchRecordingViewModel()
        viewModel.recordingState = .recording
        viewModel.recordingTime = 45
        viewModel.batteryLevel = 0.75
        viewModel.connectionState = .connected
        return viewModel
    }
}
#endif