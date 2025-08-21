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
    @Published var batteryLevel: Float = 1.0
    @Published var isPhoneAppActive: Bool = false
    @Published var errorMessage: String?
    @Published var showingError: Bool = false
    @Published var isTransferringAudio: Bool = false
    @Published var transferProgress: Double = 0.0
    @Published var isActivatingPhoneApp: Bool = false
    @Published var showingActivationAlert: Bool = false
    @Published var activationStatusMessage: String = ""
    @Published var activationFailed: Bool = false
    @Published var localRecordings: [WatchRecordingMetadata] = []
    @Published var pendingSyncCount: Int = 0
    
    // MARK: - Private Properties
    private let audioManager = WatchAudioManager()
    private let connectivityManager = WatchConnectivityManager.shared
    private let feedbackManager = WatchFeedbackManager()
    private let locationManager = WatchLocationManager()
    private var cancellables = Set<AnyCancellable>()
    private var recordingSessionId: UUID?
    private var isWatchInitiatedRecording: Bool = false
    private var currentSyncOperation: WatchSyncOperation?
    private var recordingStartLocation: WatchLocationData?
    
    // App activation tracking
    private var activationRetryCount = 0
    private let maxActivationRetries = 3
    private let activationTimeout: TimeInterval = 10.0
    
    // Sync retry tracking
    private let maxSyncRetries = 3
    private let syncRetryDelays: [TimeInterval] = [2.0, 5.0, 10.0] // Exponential backoff
    
    // Timeout tracking
    private var currentTimeoutTimer: Timer?
    
    // MARK: - Computed Properties
    
    var canStartRecording: Bool {
        return recordingState.canStartRecording // No connection requirement - watch operates independently
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
    
    
    // MARK: - Initialization
    
    init() {
        setupAudioManager()
        setupConnectivityManager()
        setupLocationManager()
        setupBindings()
        updateBatteryLevel()
        
        // Clean up any previously synced recordings that weren't deleted
        cleanupSyncedRecordings()
        
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
        
        audioManager.onRecordingCompleted = { [weak self] metadata in
            Task { @MainActor in
                self?.handleRecordingCompleted(metadata)
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
    
    private func setupLocationManager() {
        // Request location permission when app starts
        locationManager.requestLocationPermission()
        
        print("📍⌚ Location manager setup completed")
    }
    
    private func setupBindings() {
        // Set up notification observers for watch connectivity responses
        setupNotificationObservers()
        
        // Bind audio manager properties
        audioManager.$recordingTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingTime)
        
        audioManager.$localRecordings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordings in
                self?.localRecordings = recordings
                self?.pendingSyncCount = recordings.filter { $0.syncStatus.needsSync }.count
            }
            .store(in: &cancellables)
        
        
        audioManager.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLevel in
                guard let self = self else { return }
                let oldLevel = self.batteryLevel
                self.batteryLevel = newLevel
                
                // Battery level warning is handled by feedback manager below
                
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
    
    private func setupNotificationObservers() {
        // Listen for app readiness response from phone
        NotificationCenter.default.publisher(for: Notification.Name("WatchAppReadinessResponse"))
            .compactMap { $0.object as? WatchAppReadinessResponse }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleAppReadinessResponse(response)
            }
            .store(in: &cancellables)
        
        // Listen for sync response from phone
        NotificationCenter.default.publisher(for: Notification.Name("WatchSyncResponse"))
            .compactMap { $0.object as? WatchSyncResponse }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleSyncResponse(response)
            }
            .store(in: &cancellables)
        
        // Listen for sync complete notification
        NotificationCenter.default.publisher(for: Notification.Name("WatchSyncComplete"))
            .compactMap { $0.object as? UUID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordingId in
                self?.handleSyncCompleted(recordingId)
            }
            .store(in: &cancellables)
        
        // Listen for sync failed notification
        NotificationCenter.default.publisher(for: Notification.Name("WatchSyncFailed"))
            .compactMap { $0.object as? [String: Any] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                if let recordingId = info["recordingId"] as? UUID,
                   let reason = info["reason"] as? String {
                    self?.handleSyncFailed(recordingId, reason: reason)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Interface
    
    /// Start recording audio (watch operates independently)
    func startRecording() {
        guard canStartRecording else {
            showError("Cannot start recording: \(recordingState.description)")
            return
        }
        
        print("⌚ Starting recording...")
        
        // Watch records independently - always start recording immediately
        initiateRecording()
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
        
        // Note: Watch recording is independent - no need to notify phone
        
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
        // Note: Watch recording is independent - no need to notify phone
        
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
        // Note: Watch recording is independent - no need to notify phone
        
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
    
    
    /// Initiate local-only recording when iPhone unavailable
    private func initiateLocalRecording() {
        // Start recording directly - will be saved locally
        initiateRecording()
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
        // Check storage before starting recording
        if !checkStorageAvailable() {
            showError("Insufficient storage available for recording")
            return
        }
        
        // Mark this as a watch-initiated recording
        isWatchInitiatedRecording = true
        recordingSessionId = UUID() // Generate session ID to match with location data
        
        // Capture location at recording start
        captureRecordingLocation()
        
        // Update UI immediately for responsiveness
        let oldState = recordingState
        recordingState = .recording
        feedbackManager.feedbackForRecordingStateChange(from: oldState, to: .recording)
        
        // Start local audio recording asynchronously to avoid blocking UI
        Task { @MainActor in
            let success = await startRecordingAsync()
            if !success {
                // Revert state if recording failed
                recordingState = oldState
                isWatchInitiatedRecording = false
                recordingStartLocation = nil // Clear location on failure
            }
        }
    }
    
    /// Capture location at the start of recording
    private func captureRecordingLocation() {
        guard locationManager.isLocationAvailable else {
            print("📍⌚ Location not available for recording")
            return
        }
        
        locationManager.getCurrentLocation { [weak self] location in
            Task { @MainActor in
                if let location = location {
                    let watchLocationData = WatchLocationData(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        timestamp: location.timestamp,
                        accuracy: location.horizontalAccuracy
                    )
                    self?.recordingStartLocation = watchLocationData
                    print("📍⌚ Captured recording location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                } else {
                    print("📍⌚ Failed to get recording location")
                }
            }
        }
    }
    
    /// Async wrapper for audio recording startup
    private func startRecordingAsync() async -> Bool {
        if !audioManager.startRecording() {
            // If recording failed, try to recover from stuck state
            print("⌚ Recording failed, attempting to recover from stuck state...")
            audioManager.forceResetRecordingState()
            
            // Try one more time after reset
            guard audioManager.startRecording() else {
                await MainActor.run {
                    showError("Failed to start audio recording after recovery attempt")
                }
                return false
            }
            
            print("⌚ Recording recovered successfully after state reset")
        }
        
        // Generate session ID
        recordingSessionId = audioManager.getCurrentSessionId()
        
        print("⌚ Recording initiated with session ID: \(recordingSessionId?.uuidString ?? "unknown")")
        return true
    }
    
    /// Check if there's sufficient storage for recording
    private func checkStorageAvailable() -> Bool {
        let storage = audioManager.getRecordingStorage()
        let estimatedRecordingSize: Int64 = 5 * 1024 * 1024 // Assume 5MB per recording
        
        return storage.hasSpaceForRecording(estimatedSize: estimatedRecordingSize)
    }
    
    private func sendCurrentStateToPhone() {
        // Watch operates independently - no need to send state to phone
        // State updates only needed for file sync operations
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
        
        // Note: Watch operates independently - no state updates to phone during recording
        
        print("⌚ Audio recording state changed: \(recordingState.rawValue)")
    }
    
    /// Sync a recording to iPhone
    func syncRecording(_ recording: WatchRecordingMetadata) {
        guard !isTransferringAudio else {
            showError("Sync already in progress")
            return
        }
        
        // Check iPhone connectivity first
        if !connectivityManager.connectionState.isConnected {
            showError("iPhone not connected")
            return
        }
        
        print("⌚ Starting sync for recording: \(recording.filename)")
        startRecordingSync(recording)
    }
    
    /// Sync all pending recordings
    func syncAllRecordings() {
        let pendingRecordings = audioManager.getRecordingsPendingSync()
        guard !pendingRecordings.isEmpty else {
            showError("No recordings to sync")
            return
        }
        
        print("⌚ Starting sync for \(pendingRecordings.count) recordings")
        
        // Start with first recording
        if let firstRecording = pendingRecordings.first {
            syncRecording(firstRecording)
        }
    }
    
    private func handleRecordingCompleted(_ metadata: WatchRecordingMetadata?) {
        guard let metadata = metadata else {
            print("❌ Recording completed but no metadata saved")
            recordingState = .error
            showError("Failed to save recording")
            return
        }
        
        print("⌚ Recording completed and saved locally: \(metadata.filename)")
        
        // Update state
        recordingState = .processing
        recordingSessionId = nil
        
        // Check if iPhone is available for immediate sync
        if connectivityManager.connectionState.isConnected && isPhoneAppActive {
            // Start sync automatically
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.syncRecording(metadata)
            }
        } else {
            // iPhone not available, proceed with local recording
            recordingState = .idle
            initiateLocalRecording()
        }
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
        
        // Watch operates independently - ignore phone recording state changes
        print("⌚ Watch operates independently, ignoring phone state change")
        return
    }
    
    private func handlePhoneAppActivated() {
        print("⌚ Phone app activated")
        isPhoneAppActive = true
        
        // If we were trying to activate, mark as successful
        if isActivatingPhoneApp {
            handleActivationSuccess()
        }
        
        // Check if there are any failed recordings that can now be retried
        let storage = audioManager.getRecordingStorage()
        let failedRecordings = storage.localRecordings.filter { $0.syncStatus == .syncFailed }
        
        if !failedRecordings.isEmpty {
            print("⌚ iPhone app now active - found \(failedRecordings.count) failed recordings to retry")
            
            // Reset sync status and retry first failed recording
            if let firstFailed = failedRecordings.first {
                storage.updateSyncStatus(firstFailed.id, status: .pendingSync, attempts: 0)
                
                // Wait a moment for app to fully activate, then retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let retryRecording = storage.localRecordings.first(where: { $0.id == firstFailed.id }) {
                        print("⌚ Auto-retrying sync for: \(retryRecording.filename)")
                        self.syncRecording(retryRecording)
                    }
                }
            }
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
            
            // Note: Success feedback provided only at final sync completion, not intermediate transfer
        } else {
            print("⌚ Audio transfer failed")
            showError("Failed to transfer audio to phone")
            recordingState = .error
            
            // Provide failure feedback
            feedbackManager.feedbackForTransferProgress(completed: false, failed: true)
        }
    }
    
    // MARK: - Recording Sync Implementation
    
    private func startRecordingSync(_ recording: WatchRecordingMetadata) {
        currentSyncOperation = WatchSyncOperation(recording: recording)
        isTransferringAudio = true
        transferProgress = 0.0
        
        // Update recording status to syncing
        audioManager.getRecordingStorage().updateSyncStatus(recording.id, status: .syncing)
        
        // Step 1: Check iPhone app readiness
        checkiPhoneAppReadiness(for: recording)
    }
    
    private func checkiPhoneAppReadiness(for recording: WatchRecordingMetadata) {
        guard currentSyncOperation != nil else { return }
        
        print("⌚ Checking iPhone app readiness for sync...")
        transferProgress = 0.1
        
        // Send readiness check message
        connectivityManager.sendRecordingCommand(.checkAppReadiness, additionalInfo: [
            "recordingId": recording.id.uuidString,
            "fileSize": recording.fileSize,
            "duration": recording.duration
        ])
        
        // Set timeout for readiness response
        currentTimeoutTimer?.invalidate()
        currentTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      self.currentSyncOperation?.recording.id == recording.id else { return }
                self.handleSyncTimeout("iPhone app readiness check timed out")
            }
        }
    }
    
    private func handleiPhoneAppReady(for recording: WatchRecordingMetadata) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recording.id else { return }
        
        // Cancel readiness timeout since we got the response
        currentTimeoutTimer?.invalidate()
        
        print("⌚ iPhone app ready, starting file transfer...")
        transferProgress = 0.2
        
        // Step 2: Initiate sync request
        let storage = audioManager.getRecordingStorage()
        let checksum = storage.calculateChecksum(for: recording)
        
        // Create location data dictionary if available
        var syncData: [String: Any] = [
            "recordingId": recording.id.uuidString,
            "filename": recording.filename,
            "duration": recording.duration,
            "fileSize": recording.fileSize,
            "createdAt": recording.createdAt.timeIntervalSince1970,
            "checksumMD5": checksum ?? ""
        ]
        
        // Add location data if available from recent recording
        if let locationData = recordingStartLocation {
            // Check if this location data is recent (within last 5 minutes)
            let locationAge = Date().timeIntervalSince(locationData.timestamp)
            if locationAge < 300 { // 5 minutes
                syncData["locationData"] = locationData.toDictionary()
                print("📍⌚ Including recent location data in sync request (age: \(Int(locationAge))s)")
            } else {
                print("📍⌚ Location data too old (\(Int(locationAge))s), not including")
            }
        } else {
            print("📍⌚ No location data available for sync")
        }
        
        connectivityManager.sendRecordingCommand(.syncRequest, additionalInfo: syncData)
        
        // Set timeout for sync response
        currentTimeoutTimer?.invalidate()
        currentTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      self.currentSyncOperation?.recording.id == recording.id else { return }
                self.handleSyncTimeout("Sync request timed out")
            }
        }
    }
    
    private func handleSyncAccepted(for recording: WatchRecordingMetadata) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recording.id else { return }
        
        // Cancel sync request timeout since we got the response
        currentTimeoutTimer?.invalidate()
        
        print("⌚ Sync accepted, transferring file...")
        transferProgress = 0.4
        
        // Step 3: Transfer complete file
        let storage = audioManager.getRecordingStorage()
        let fileURL = storage.fileURL(for: recording)
        
        connectivityManager.transferCompleteRecording(fileURL: fileURL, metadata: recording) { [weak self] (success: Bool) in
            guard let self = self else { return }
            
            if success {
                self.handleFileTransferComplete(for: recording)
            } else {
                self.handleSyncFailure("File transfer failed")
            }
        }
    }
    
    private func handleFileTransferComplete(for recording: WatchRecordingMetadata) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recording.id else { return }
        
        print("⌚ File transfer complete, waiting for Core Data confirmation...")
        transferProgress = 0.8
        
        // Set timeout for Core Data confirmation (iPhone might be backgrounded)
        currentTimeoutTimer?.invalidate()
        currentTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let currentOp = self.currentSyncOperation,
                      currentOp.recording.id == recording.id else { return }
                
                print("⌚ Core Data confirmation timeout - assuming sync completed successfully")
                // File transfer completed, assume iPhone will process in background
                self.handleSyncComplete(for: recording)
            }
        }
    }
    
    private func handleSyncComplete(for recording: WatchRecordingMetadata) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recording.id else { return }
        
        // Cancel any pending timeout
        currentTimeoutTimer?.invalidate()
        
        print("✅ Sync completed successfully for: \(recording.filename)")
        transferProgress = 1.0
        
        // Update recording status to synced and delete from local storage
        let storage = audioManager.getRecordingStorage()
        storage.updateSyncStatus(recording.id, status: .synced)
        
        // Delete the recording from local storage since it's now safely on the iPhone
        storage.deleteRecording(recording)
        print("🗑️ Deleted synced recording from watch: \(recording.filename)")
        
        // Cleanup
        currentSyncOperation = nil
        isTransferringAudio = false
        
        // Provide success feedback
        feedbackManager.feedbackForTransferProgress(completed: true)
        
        // If there are more recordings to sync, continue
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let pendingRecordings = self.audioManager.getRecordingsPendingSync()
            if let nextRecording = pendingRecordings.first {
                self.syncRecording(nextRecording)
            }
        }
    }
    
    private func handleSyncFailure(_ reason: String) {
        guard let operation = currentSyncOperation else { return }
        
        // Cancel any pending timeout
        currentTimeoutTimer?.invalidate()
        
        print("❌ Sync failed: \(reason)")
        
        // Update recording status and attempt count
        let storage = audioManager.getRecordingStorage()
        let currentAttempts = operation.recording.syncAttempts + 1
        
        // Check if we should retry
        if currentAttempts < maxSyncRetries {
            print("⌚ Scheduling sync retry \(currentAttempts + 1)/\(maxSyncRetries) for: \(operation.recording.filename)")
            
            // Update attempt count but keep status as syncing for retry
            storage.updateSyncStatus(operation.recording.id, status: .syncing, attempts: currentAttempts)
            
            // Clean up current operation
            currentSyncOperation = nil
            isTransferringAudio = false
            transferProgress = 0.0
            
            // Schedule retry with exponential backoff
            let retryIndex = min(currentAttempts - 1, syncRetryDelays.count - 1)
            let retryDelay = syncRetryDelays[retryIndex]
            
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self = self else { return }
                
                // Get updated recording metadata from storage
                let storage = self.audioManager.getRecordingStorage()
                if let updatedRecording = storage.localRecordings.first(where: { $0.id == operation.recording.id }) {
                    print("⌚ Retrying sync for: \(updatedRecording.filename) (attempt \(currentAttempts + 1))")
                    self.syncRecording(updatedRecording)
                }
            }
            
            return
        }
        
        // Max retries reached, mark as permanently failed
        print("❌ Max sync retries reached for: \(operation.recording.filename)")
        storage.updateSyncStatus(operation.recording.id, status: .syncFailed, attempts: currentAttempts)
        
        // Cleanup
        currentSyncOperation = nil
        isTransferringAudio = false
        transferProgress = 0.0
        
        // Show sync failure error
        showError("Sync failed: \(reason) (after \(currentAttempts) attempts)")
        
        // Provide failure feedback
        feedbackManager.feedbackForTransferProgress(completed: false, failed: true)
        
        recordingState = .idle
    }
    
    private func handleSyncTimeout(_ reason: String) {
        handleSyncFailure(reason)
    }
    
    private func handleAppReadinessResponse(_ response: WatchAppReadinessResponse) {
        guard let operation = currentSyncOperation else {
            print("⌚ Received app readiness response but no sync operation in progress")
            return
        }
        
        print("⌚ Processing app readiness response: \(response.ready ? "ready" : "not ready") - \(response.reason)")
        
        if response.ready {
            // Phone app is ready, proceed to next step
            handleiPhoneAppReady(for: operation.recording)
        } else {
            // Phone app is not ready, fail the sync
            handleSyncFailure("iPhone app not ready: \(response.reason)")
        }
    }
    
    private func handleSyncResponse(_ response: WatchSyncResponse) {
        guard let operation = currentSyncOperation,
              operation.recording.id == response.recordingId else {
            print("⌚ Received sync response but no matching sync operation in progress")
            return
        }
        
        print("⌚ Processing sync response: \(response.accepted ? "accepted" : "rejected")")
        
        if response.accepted {
            // Sync accepted, proceed to file transfer
            handleSyncAccepted(for: operation.recording)
        } else {
            // Sync rejected, fail the sync
            let reason = response.reason ?? "Unknown reason"
            handleSyncFailure("Sync rejected: \(reason)")
        }
    }
    
    private func handleSyncCompleted(_ recordingId: UUID) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recordingId else {
            print("⌚ Received sync complete but no matching sync operation in progress")
            return
        }
        
        // Delegate to main sync complete handler (which includes logging)
        handleSyncComplete(for: operation.recording)
    }
    
    private func handleSyncFailed(_ recordingId: UUID, reason: String) {
        guard let operation = currentSyncOperation,
              operation.recording.id == recordingId else {
            print("⌚ Received sync failed but no matching sync operation in progress")
            return
        }
        
        print("❌ Sync failed for: \(operation.recording.filename), reason: \(reason)")
        handleSyncFailure(reason)
    }
    
    // MARK: - Cleanup Methods
    
    /// Clean up any recordings that are marked as synced but still stored locally
    private func cleanupSyncedRecordings() {
        let storage = audioManager.getRecordingStorage()
        let syncedRecordings = storage.localRecordings.filter { $0.syncStatus == .synced }
        
        if !syncedRecordings.isEmpty {
            print("🧹 Cleaning up \(syncedRecordings.count) previously synced recordings...")
            for recording in syncedRecordings {
                storage.deleteRecording(recording)
                print("🗑️ Deleted synced recording: \(recording.filename)")
            }
        }
    }
    
    // MARK: - Battery Monitoring
    
    private func updateBatteryLevel() {
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        batteryLevel = device.batteryLevel
        print("⌚ Battery level updated: \(Int(batteryLevel * 100))%")
        #endif
    }
}

// MARK: - Supporting Types

struct WatchSyncOperation {
    let recording: WatchRecordingMetadata
    let startedAt: Date
    
    init(recording: WatchRecordingMetadata) {
        self.recording = recording
        self.startedAt = Date()
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
        return viewModel
    }
}
#endif