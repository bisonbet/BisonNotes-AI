//
//  WatchRecordingViewModel.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import Foundation
import SwiftUI
import Combine
import os.log

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
    @Published var localRecordings: [WatchRecordingMetadata] = []
    @Published var pendingSyncCount: Int = 0

    // MARK: - Private Properties
    private let audioManager = WatchAudioManager()
    private let connectivityManager = WatchConnectivityManager.shared
    private let feedbackManager = WatchFeedbackManager()
    private let locationManager = WatchLocationManager()
    private var cancellables = Set<AnyCancellable>()
    private var recordingSessionId: UUID?
    private var recordingStartLocation: WatchLocationData?
    
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

        // Pick up recordings that never made it to the iPhone (offline
        // recordings, crashes, etc.) and queue them for reliable transfer
        enqueuePendingRecordings()

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

        connectivityManager.onConnectionRestored = { [weak self] in
            Task { @MainActor in
                self?.enqueuePendingRecordings()
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
        
        // Set up app lifecycle observers for recording protection
        setupAppLifecycleObservers()
        
        // Bind audio manager properties
        audioManager.$recordingTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingTime)
        
        audioManager.$localRecordings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordings in
                self?.localRecordings = recordings
                // Include both local pending and reliable transfers in count
                let localPendingCount = recordings.filter { $0.syncStatus.needsSync }.count
                let reliablePendingCount = self?.connectivityManager.pendingReliableTransfersCount ?? 0
                self?.pendingSyncCount = localPendingCount + reliablePendingCount
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
    
    private func setupAppLifecycleObservers() {
        #if canImport(WatchKit)
        // Listen for app lifecycle events to protect recording sessions
        NotificationCenter.default.publisher(for: WKExtension.applicationWillResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppWillResignActive()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: WKExtension.applicationDidBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppDidBecomeActive()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: WKExtension.applicationDidEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppDidEnterBackground()
                }
            }
            .store(in: &cancellables)
        #endif
    }
    
    private func setupNotificationObservers() {
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
        // Recover from a stale error state so "Try Again" actually retries
        if recordingState == .error {
            recordingState = .idle
            errorMessage = nil
            showingError = false
        }

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
        enqueuePendingRecordings()
    }
    
    /// Dismiss current error
    func dismissError() {
        errorMessage = nil
        showingError = false

        // Leaving recordingState stuck at .error would keep the error overlay
        // up and block the record button's start path
        if recordingState == .error {
            recordingState = .idle
        }
    }
    

    // MARK: - Private Methods

    private func initiateRecording() {
        // Check storage before starting recording
        if !checkStorageAvailable() {
            showError("Insufficient storage available for recording")
            return
        }
        
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
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.watchapp", category: "Recording").debug("Captured recording location, accuracy: \(location.horizontalAccuracy, privacy: .public)m")
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

        // Keep the connectivity manager informed so it can minimize
        // connectivity work while a recording session is active
        connectivityManager.watchRecordingState = recordingState

        print("⌚ Audio recording state changed: \(recordingState.rawValue)")
    }
    
    /// Sync a recording to iPhone
    func syncRecording(_ recording: WatchRecordingMetadata) {
        enqueueRecordingForSync(recording)
    }

    /// Sync all pending recordings
    func syncAllRecordings() {
        let pendingRecordings = audioManager.getRecordingsPendingSync()
        guard !pendingRecordings.isEmpty else {
            showError("No recordings to sync")
            return
        }

        print("⌚ Starting sync for \(pendingRecordings.count) recordings")
        for recording in pendingRecordings {
            enqueueRecordingForSync(recording)
        }
    }

    /// Add a recording to the reliable transfer queue
    private func enqueueRecordingForSync(_ recording: WatchRecordingMetadata) {
        let storage = audioManager.getRecordingStorage()
        storage.updateSyncStatus(recording.id, status: .pendingSync)

        let fileURL = storage.fileURL(for: recording)
        connectivityManager.transferCompleteRecording(fileURL: fileURL, metadata: recording) { _ in }
    }

    /// Re-enqueue any recordings that still need syncing (recordings made while
    /// the iPhone was unreachable, or left over after a crash/relaunch)
    private func enqueuePendingRecordings() {
        let pending = audioManager.getRecordingsPendingSync()
        guard !pending.isEmpty else { return }

        print("⌚ Re-enqueueing \(pending.count) pending recordings for sync")
        for recording in pending where !connectivityManager.hasReliableTransfer(for: recording.id) {
            enqueueRecordingForSync(recording)
        }
    }
    
    private func handleRecordingCompleted(_ metadata: WatchRecordingMetadata?) {
        guard let metadata = metadata else {
            print("❌ Recording completed but no metadata saved")
            recordingState = .error
            showError("Failed to save recording")
            return
        }

        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.watchapp", category: "Recording").debug("Recording completed and saved locally")

        recordingState = .idle
        recordingSessionId = nil

        // Attach the location captured at recording start so it survives
        // queued/retried transfers
        var metadataToSync = metadata
        if let location = recordingStartLocation {
            let storage = audioManager.getRecordingStorage()
            if let updated = storage.updateLocation(metadata.id, location: location) {
                metadataToSync = updated
            }
            recordingStartLocation = nil
        }

        // Hand the recording to the reliable transfer queue unconditionally.
        // WCSession.transferFile queues across unreachability and app restarts,
        // so no connectivity gating is needed here.
        enqueueRecordingForSync(metadataToSync)
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
    
    private func handlePhoneAppActivated() {
        print("⌚ Phone app activated")
        isPhoneAppActive = true

        // Queue any recordings that still need syncing (local, pending, or failed)
        enqueuePendingRecordings()
    }

    private func handlePhoneError(_ error: WatchErrorMessage) {
        showError("Phone: \(error.message)")
    }

    // MARK: - Sync Outcome Handlers

    private func handleSyncCompleted(_ recordingId: UUID) {
        let storage = audioManager.getRecordingStorage()
        guard let recording = storage.localRecordings.first(where: { $0.id == recordingId }) else {
            print("⌚ Sync complete for unknown recording: \(recordingId)")
            return
        }

        print("✅ Sync completed successfully for: \(recording.filename)")

        // The reliable transfer system has already deleted the audio file after
        // confirmation; remove the local metadata entry too.
        storage.deleteRecording(recording)

        if recordingState == .processing {
            recordingState = .idle
        }

        // Provide success feedback
        feedbackManager.feedbackForTransferProgress(completed: true)
    }

    private func handleSyncFailed(_ recordingId: UUID, reason: String) {
        let storage = audioManager.getRecordingStorage()
        guard let recording = storage.localRecordings.first(where: { $0.id == recordingId }) else {
            print("⌚ Sync failed for unknown recording: \(recordingId)")
            return
        }

        print("❌ Sync failed for: \(recording.filename), reason: \(reason)")
        storage.updateSyncStatus(recordingId, status: .syncFailed, attempts: recording.syncAttempts + 1)

        // No error alert here: the recording is safe on the watch and the
        // reliable transfer system retries with backoff.
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
    
    // MARK: - App Lifecycle Handlers
    
    /// Handle app will resign active - protect ongoing recordings
    private func handleAppWillResignActive() {
        if recordingState == .recording || recordingState == .paused {
            print("⌚ App will resign active during recording - protecting session")
            // Ensure audio session remains active for background recording
            audioManager.maintainBackgroundRecording()
        } else {
            print("⌚ App will resign active (no recording)")
        }
    }
    
    /// Handle app became active - resume normal operations
    private func handleAppDidBecomeActive() {
        if recordingState == .recording || recordingState == .paused {
            print("⌚ App became active during recording - resuming UI and checking session")
            
            // Verify recording session is still healthy
            if !audioManager.performHealthCheck() {
                print("⚠️ Recording session compromised after system alert")
                showError("Recording was interrupted by system alert")
            }
            
            // Update UI state
            updateBatteryLevel()
        } else {
            print("⌚ App became active (normal)")
            updateBatteryLevel()
        }
    }
    
    /// Handle app entering background - minimize operations during recording
    private func handleAppDidEnterBackground() {
        if recordingState == .recording || recordingState == .paused {
            print("⌚ App entering background during recording - minimal operations")
            // Save critical state but don't interrupt recording
            audioManager.prepareForBackgroundRecording()
        } else {
            print("⌚ App entering background (normal)")
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
        return viewModel
    }
}
#endif