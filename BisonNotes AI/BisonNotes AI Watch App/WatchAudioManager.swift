//
//  WatchAudioManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//  Updated by Claude on 2025-08-21 - Converted to local recording storage
//

import Foundation
import AVFoundation
import Combine

#if canImport(WatchKit)
import WatchKit
#endif

/// Manages audio recording functionality on Apple Watch with battery optimization
@MainActor
class WatchAudioManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isRecording: Bool = false
    @Published var isPaused: Bool = false
    @Published var recordingTime: TimeInterval = 0
    @Published var batteryLevel: Float = 1.0
    // Audio quality matches iOS app whisperOptimized settings
    @Published var errorMessage: String?
    
    // Local recordings storage
    @Published var localRecordings: [WatchRecordingMetadata] = []
    
    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioSession: AVAudioSession?
    private var recordingTimer: Timer?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var lastPauseTime: Date?
    
    // Local recording session management
    private var currentSessionId: UUID?
    private let recordingStorage = WatchRecordingStorage()
    
    // Battery and performance monitoring
    private var initialBatteryLevel: Float = 1.0
    private var maxRecordingDuration: TimeInterval = 7200 // 2 hours to match iOS app
    
    // MARK: - Callbacks
    var onRecordingStateChanged: ((Bool, Bool) -> Void)? // isRecording, isPaused
    var onRecordingCompleted: ((WatchRecordingMetadata?) -> Void)?
    var onError: ((WatchAudioError) -> Void)?
    
    override init() {
        super.init()
        setupAudioSession()
        monitorBatteryLevel()
        setupStorageBinding()
    }
    
    private func setupStorageBinding() {
        // Bind storage recordings to published property
        recordingStorage.$localRecordings
            .receive(on: DispatchQueue.main)
            .assign(to: &$localRecordings)
    }
    
    deinit {
        // Clean up resources
        recordingTimer?.invalidate()
        audioRecorder?.stop()
    }
    
    // MARK: - Public Interface
    
    /// Start audio recording
    func startRecording() -> Bool {
        guard !isRecording else {
            print("⌚ Already recording")
            return false
        }
        
        // Check battery level
        guard canStartRecording() else {
            let error = WatchAudioError.batteryTooLow("Battery level too low to start recording")
            onError?(error)
            errorMessage = error.localizedDescription
            return false
        }
        
        // Request permission and setup recording
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if granted {
                    self.setupAndStartRecording()
                } else {
                    let error = WatchAudioError.permissionDenied("Microphone permission denied")
                    self.onError?(error)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        
        return true
    }
    
    /// Stop audio recording
    func stopRecording() {
        guard isRecording || isPaused else { return }
        
        audioRecorder?.stop()
        stopAllTimers()
        
        isRecording = false
        isPaused = false
        
        // Note: Don't reset recordingTime here, we need it for finalization
        // Don't call finalizeRecording() here - it will be called by the delegate
        
        onRecordingStateChanged?(false, false)
        print("⌚ Recording stopped")
    }
    
    /// Force reset recording state - use when the recorder gets stuck
    func forceResetRecordingState() {
        print("⌚ Force resetting recording state")
        
        // Stop any active recorder
        audioRecorder?.stop()
        audioRecorder = nil
        
        // Reset all state
        isRecording = false
        isPaused = false
        recordingTime = 0
        
        // Stop timers
        stopAllTimers()
        
        // Clear error state
        errorMessage = nil
        
        // Notify state change
        onRecordingStateChanged?(false, false)
        
        print("⌚ Recording state reset completed")
    }
    
    /// Pause audio recording
    func pauseRecording() {
        guard isRecording && !isPaused else { return }
        
        audioRecorder?.pause()
        isPaused = true
        lastPauseTime = Date()
        
        // Pause timers but keep level monitoring
        recordingTimer?.invalidate()
        
        onRecordingStateChanged?(true, true)
        print("⌚ Recording paused")
    }
    
    /// Resume audio recording
    func resumeRecording() {
        guard isRecording && isPaused else { return }
        
        // Calculate paused duration
        if let pauseTime = lastPauseTime {
            pausedDuration += Date().timeIntervalSince(pauseTime)
        }
        
        audioRecorder?.record()
        isPaused = false
        lastPauseTime = nil
        
        // Resume timers
        startRecordingTimer()
        
        onRecordingStateChanged?(true, false)
        print("⌚ Recording resumed")
    }
    
    /// Get current recording session ID
    func getCurrentSessionId() -> UUID? {
        return currentSessionId
    }
    
    /// Get local recordings storage
    func getRecordingStorage() -> WatchRecordingStorage {
        return recordingStorage
    }
    
    /// Get recordings pending sync
    func getRecordingsPendingSync() -> [WatchRecordingMetadata] {
        return recordingStorage.getRecordingsPendingSync()
    }
    
    /// Emergency stop recording due to critical issues
    func emergencyStopRecording(reason: String) {
        print("🚨 Emergency stop recording: \(reason)")
        
        if isRecording || isPaused {
            // Save current state
            let currentTime = recordingTime
            
            // Stop recording immediately
            audioRecorder?.stop()
            stopAllTimers()
            
            // Set error state
            isRecording = false
            isPaused = false
            errorMessage = "Recording stopped: \(reason)"
            
            // Notify about the emergency stop
            let error = WatchAudioError.recordingFailed("Emergency stop: \(reason)")
            onError?(error)
            onRecordingStateChanged?(false, false)
            
            // Reset timing
            recordingTime = 0
            pausedDuration = 0
            
            print("🚨 Emergency stop completed. Recording time: \(currentTime) seconds")
        }
    }
    
    /// Maintain recording session during background/system alerts
    func maintainBackgroundRecording() {
        guard isRecording || isPaused else { return }
        
        print("⌚ Maintaining background recording session")
        
        do {
            // Ensure audio session remains active with high priority
            try audioSession?.setActive(true, options: [])
            
            // Keep the recording process alive during system alerts
            if let recorder = audioRecorder, recorder.isRecording {
                print("⌚ Audio recorder confirmed active during background transition")
            } else if isPaused {
                print("⌚ Recording is paused, maintaining session state")
            }
        } catch {
            print("⚠️ Failed to maintain background audio session: \(error)")
            // Don't emergency stop - let the user decide what to do
        }
    }
    
    /// Prepare for background recording state
    func prepareForBackgroundRecording() {
        guard isRecording || isPaused else { return }
        
        print("⌚ Preparing for background recording state")
        
        // Ensure audio session is configured for background operation
        do {
            // Set category with background capability
            try audioSession?.setCategory(.record, mode: .default, options: [.allowBluetooth, .mixWithOthers])
            try audioSession?.setActive(true, options: [])
            
            print("⌚ Background recording prepared successfully")
        } catch {
            print("⚠️ Failed to prepare background recording: \(error)")
            // Log but don't stop - recording may continue anyway
        }
    }
    
    /// Check recording health and handle issues
    func performHealthCheck() -> Bool {
        // Check battery level
        updateBatteryLevel()
        if batteryLevel <= 0.05 { // 5% critical
            emergencyStopRecording(reason: "Critical battery level")
            return false
        }
        
        // Check if recording is still active
        if isRecording, let recorder = audioRecorder, !recorder.isRecording {
            print("⚠️ Audio recorder stopped unexpectedly")
            emergencyStopRecording(reason: "Audio recorder failure")
            return false
        }
        
        // Check storage space (basic check)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documentsPath = documentsURL?.path {
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: documentsPath)
                if let freeSpace = attributes[.systemFreeSize] as? Int64 {
                    let freeSpaceMB = freeSpace / (1024 * 1024)
                    if freeSpaceMB < 50 { // Less than 50MB
                        emergencyStopRecording(reason: "Low storage space")
                        return false
                    }
                }
            } catch {
                print("⚠️ Could not check storage space: \(error)")
            }
        }
        
        return true
    }
    
    
    // MARK: - Private Methods
    
    private func setupAudioSession() {
        audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession?.setCategory(.record, mode: .default, options: [.allowBluetooth])
            // Use notifyOthersOnDeactivation to be more cooperative with system sessions
            try audioSession?.setActive(true, options: .notifyOthersOnDeactivation)
            print("⌚ Audio session configured successfully")
        } catch {
            print("⌚ Failed to configure audio session: \(error)")
            let audioError = WatchAudioError.configurationFailed("Failed to configure audio session: \(error.localizedDescription)")
            onError?(audioError)
            errorMessage = audioError.localizedDescription
        }
    }
    
    private func setupAndStartRecording() {
        // Generate unique session ID and recording URL
        currentSessionId = UUID()
        
        recordingURL = createRecordingURL()
        guard let url = recordingURL else {
            let error = WatchAudioError.fileSystemError("Failed to create recording file")
            onError?(error)
            errorMessage = error.localizedDescription
            return
        }
        
        // Configure recorder with whisperOptimized settings (matching iOS app)
        let settings = whisperOptimizedAudioSettings
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            
            // Start recording
            guard audioRecorder?.record() == true else {
                throw WatchAudioError.recordingFailed("Failed to start audio recorder")
            }
            
            isRecording = true
            isPaused = false
            recordingTime = 0
            recordingStartTime = Date()
            initialBatteryLevel = batteryLevel
            
            // Start timer for time tracking and health checks
            startRecordingTimer()
            
            onRecordingStateChanged?(true, false)
            print("⌚ Recording started successfully")
            
        } catch {
            print("⌚ Failed to start recording: \(error)")
            
            // Reset recording state on error
            isRecording = false
            isPaused = false
            recordingTime = 0
            
            let audioError = WatchAudioError.recordingFailed(error.localizedDescription)
            onError?(audioError)
            errorMessage = audioError.localizedDescription
        }
    }
    
    private func createRecordingURL() -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let timestamp = Date().timeIntervalSince1970
        let filename = "watchrecording-\(Int(timestamp)).m4a"
        return documentsPath?.appendingPathComponent(filename)
    }
    
    private func canStartRecording() -> Bool {
        updateBatteryLevel()
        
        let batteryThreshold: Float = 0.15 // 15% minimum
        let hasEnoughBattery = batteryLevel > batteryThreshold
        
        if !hasEnoughBattery {
            print("⌚ Battery too low for recording: \(Int(batteryLevel * 100))%")
        }
        
        return hasEnoughBattery
    }
    
    /// Audio settings matching iOS app whisperOptimized quality EXACTLY
    private var whisperOptimizedAudioSettings: [String: Any] {
        return [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,  // 22.05 kHz to match iPhone app exactly
            AVNumberOfChannelsKey: 1,  // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64000  // 64 kbps to match iPhone app exactly
        ]
    }
    
    private func updateBatteryLevel() {
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        batteryLevel = device.batteryLevel
        #else
        // Fallback for non-watchOS platforms (e.g., when building for iOS simulator)
        batteryLevel = 1.0
        #endif
    }
    
    private func monitorBatteryLevel() {
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.updateBatteryLevel()
                
                if self.isRecording {
                    self.checkBatteryDuringRecording()
                }
            }
        }
    }
    
    private func checkBatteryDuringRecording() {
        let criticalLevel: Float = 0.05 // 5%
        
        if batteryLevel <= criticalLevel {
            print("⌚ Critical battery level during recording, stopping...")
            let error = WatchAudioError.batteryTooLow("Recording stopped due to critical battery level")
            onError?(error)
            stopRecording()
        }
    }
    
    // MARK: - Timer Management
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                guard let startTime = self.recordingStartTime else { return }
                
                if !self.isPaused {
                    self.recordingTime = Date().timeIntervalSince(startTime) - self.pausedDuration
                }
                
                // Perform health check every 10 seconds
                let elapsedSeconds = Int(self.recordingTime)
                if elapsedSeconds > 0 && elapsedSeconds % 10 == 0 {
                    if !self.performHealthCheck() {
                        return // Health check failed, recording was stopped
                    }
                }
                
                // Check maximum recording duration
                if self.recordingTime >= self.maxRecordingDuration {
                    print("⌚ Maximum recording duration reached")
                    self.stopRecording()
                }
            }
        }
    }
    
    private func stopAllTimers() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    
    // MARK: - Recording Completion
    
    /// Finalize recording and save to local storage
    private func finalizeRecording() {
        guard let url = recordingURL,
              let sessionId = currentSessionId,
              FileManager.default.fileExists(atPath: url.path) else {
            print("⌚ Recording file not found for finalization")
            onRecordingCompleted?(nil)
            return
        }
        
        print("⌚ Finalizing recording session: \(sessionId)")
        
        // Save the recording to local storage
        let metadata = recordingStorage.saveRecording(
            audioFileURL: url,
            sessionId: sessionId,
            duration: recordingTime
        )
        
        if let metadata = metadata {
            print("✅ Recording saved locally: \(metadata.filename) (\(metadata.duration)s)")
        } else {
            print("❌ Failed to save recording locally")
        }
        
        // Clean up temporary recording file
        do {
            try FileManager.default.removeItem(at: url)
            print("🗑 Cleaned up temporary recording file")
        } catch {
            print("⚠️ Failed to clean up temporary file: \(error)")
        }
        
        // Reset session state
        currentSessionId = nil
        recordingURL = nil
        
        // Notify completion
        onRecordingCompleted?(metadata)
    }
    
}

// MARK: - AVAudioRecorderDelegate

extension WatchAudioManager: AVAudioRecorderDelegate {
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            print("⌚ Audio recorder finished, success: \(flag)")
            
            // Clean up state first
            isRecording = false
            isPaused = false
            stopAllTimers()
            
            if flag {
                // Successfully recorded, now finalize the chunks
                finalizeRecording()
            } else {
                print("⌚ Audio recorder finished with error")
                let error = WatchAudioError.recordingFailed("Recording completed unsuccessfully")
                onError?(error)
                errorMessage = error.localizedDescription
            }
            
            // Reset timing for next recording
            recordingTime = 0
            pausedDuration = 0
            
            onRecordingStateChanged?(false, false)
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            print("⌚ Audio recorder encode error: \(error?.localizedDescription ?? "Unknown error")")
            
            let audioError = WatchAudioError.recordingFailed(error?.localizedDescription ?? "Encoding error occurred")
            onError?(audioError)
            errorMessage = audioError.localizedDescription
            
            stopRecording()
        }
    }
}

// MARK: - Supporting Types

/// Watch-specific audio errors
enum WatchAudioError: LocalizedError {
    case permissionDenied(String)
    case batteryTooLow(String)
    case configurationFailed(String)
    case recordingFailed(String)
    case fileSystemError(String)
    case transferFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let message):
            return "Permission Denied: \(message)"
        case .batteryTooLow(let message):
            return "Battery Too Low: \(message)"
        case .configurationFailed(let message):
            return "Configuration Failed: \(message)"
        case .recordingFailed(let message):
            return "Recording Failed: \(message)"
        case .fileSystemError(let message):
            return "File System Error: \(message)"
        case .transferFailed(let message):
            return "Transfer Failed: \(message)"
        }
    }
}