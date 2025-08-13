//
//  EnhancedAudioSessionManager.swift
//  Audio Journal
//
//  Created by Kiro on 7/29/25.
//

import Foundation
import AVFoundation
import UIKit

/// Enhanced audio session manager that supports mixed audio recording and background operations
class EnhancedAudioSessionManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isConfigured = false
    @Published var isMixedAudioEnabled = false
    @Published var isBackgroundRecordingEnabled = false
    @Published var currentConfiguration: AudioSessionConfig?
    @Published var lastError: AudioProcessingError?
    
    // MARK: - Private Properties
    private let session = AVAudioSession.sharedInstance()
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    
    // MARK: - Configuration Structures
    struct AudioSessionConfig {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let allowMixedAudio: Bool
        let backgroundRecording: Bool
        
        static let mixedAudioRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker],
            allowMixedAudio: true,
            backgroundRecording: false
        )
        
        static let backgroundRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker],
            allowMixedAudio: true,
            backgroundRecording: true
        )
        
        static let standardRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth],
            allowMixedAudio: false,
            backgroundRecording: false
        )
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        // Defer notification observer setup to avoid potential crashes during init
        DispatchQueue.main.async { [weak self] in
            self?.setupNotificationObservers()
        }
    }
    
    deinit {
        // Remove observers synchronously since deinit cannot be async
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public Methods
    
    /// Configure audio session for mixed audio recording (allows other apps to play audio simultaneously)
    func configureMixedAudioSession() async throws {
        do {
            let config = AudioSessionConfig.mixedAudioRecording
            try await applyConfiguration(config)
            
            isMixedAudioEnabled = true
            isBackgroundRecordingEnabled = false
            currentConfiguration = config
            isConfigured = true
            
            print("✅ Mixed audio session configured successfully")

            // Prefer Bluetooth HFP if available for recording input
            await autoSelectBestInput()
            
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Mixed audio configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Configure audio session for background recording with mixed audio support
    func configureBackgroundRecording() async throws {
        // First check if background audio permission is available
        guard await checkBackgroundAudioPermission() else {
            let error = AudioProcessingError.backgroundRecordingNotPermitted
            lastError = error
            throw error
        }
        
        do {
            let config = AudioSessionConfig.backgroundRecording
            try await applyConfiguration(config)
            
            isMixedAudioEnabled = true
            isBackgroundRecordingEnabled = true
            currentConfiguration = config
            isConfigured = true
            
            print("✅ Background recording session configured successfully")

            // Prefer Bluetooth HFP if available for recording input
            await autoSelectBestInput()
            
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Background recording configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Restore audio session to previous configuration (useful after interruptions)
    func restoreAudioSession() async throws {
        guard let config = currentConfiguration else {
            // Default to mixed audio if no previous configuration
            try await configureMixedAudioSession()
            return
        }
        
        do {
            try await applyConfiguration(config)
            print("✅ Audio session restored successfully")
            
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Session restoration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Configure standard recording session (fallback for compatibility)
    func configureStandardRecording() async throws {
        do {
            let config = AudioSessionConfig.standardRecording
            try await applyConfiguration(config)
            
            isMixedAudioEnabled = false
            isBackgroundRecordingEnabled = false
            currentConfiguration = config
            isConfigured = true
            
            print("✅ Standard recording session configured successfully")
            
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Standard recording configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Configure audio session for playback
    func configurePlaybackSession() async throws {
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            
            isMixedAudioEnabled = false
            isBackgroundRecordingEnabled = false
            currentConfiguration = AudioSessionConfig.standardRecording
            isConfigured = true
            
            print("✅ Playback session configured successfully")
            
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Playback configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Set preferred audio input device
    func setPreferredInput(_ input: AVAudioSessionPortDescription) async throws {
        do {
            try session.setPreferredInput(input)
            print("✅ Preferred input set to: \(input.portName) (\(input.portType.rawValue))")
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Failed to set preferred input: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    /// Get available audio inputs
    func getAvailableInputs() -> [AVAudioSessionPortDescription] {
        return session.availableInputs ?? []
    }
    
    /// Check if mixed audio recording is currently supported
    func isMixedAudioSupported() -> Bool {
        return session.category == .playAndRecord && 
               session.categoryOptions.contains(.mixWithOthers)
    }
    
    /// Deactivate audio session
    func deactivateSession() async throws {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isConfigured = false
            print("✅ Audio session deactivated")
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Failed to deactivate session: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }
    
    // MARK: - Private Methods
    
    private func applyConfiguration(_ config: AudioSessionConfig) async throws {
        try session.setCategory(config.category, mode: config.mode, options: config.options)

        // Prefer telephony-friendly settings when recording with Bluetooth HFP
        if config.category == .playAndRecord {
            // These are best-effort; if they fail it's okay to continue
            try? session.setPreferredSampleRate(16000)
            try? session.setPreferredIOBufferDuration(0.02)
        }

        try session.setActive(true)
        
        // Additional configuration for background recording
        if config.backgroundRecording {
            // Request background audio capability
            try await requestBackgroundAudioCapability()
        }
    }
    
    private func checkBackgroundAudioPermission() async -> Bool {
        // Check if the app has background audio capability in Info.plist
        guard let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
              backgroundModes.contains("audio") else {
            print("❌ Background audio mode not configured in Info.plist")
            return false
        }
        
        return true
    }
    
    private func requestBackgroundAudioCapability() async throws {
        // This would typically involve requesting background app refresh permission
        // For now, we'll just verify the configuration is correct
        guard session.category == .playAndRecord else {
            throw AudioProcessingError.backgroundRecordingNotPermitted
        }
    }
    
    private func setupNotificationObservers() {
        // Audio interruption observer
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Capture the notification data we need before entering Task
            let userInfo = notification.userInfo
            let interruptionType = userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType
            
            Task { @MainActor in
                guard let self = self else { return }
                // Create a new notification with only the data we need
                if let type = interruptionType {
                    let newUserInfo: [String: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
                    let newNotification = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: newUserInfo)
                    self.handleAudioInterruption(newNotification)
                }
            }
        }
        
        // Route change observer
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Capture the notification data we need before entering Task
            let userInfo = notification.userInfo
            let routeChangeReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? AVAudioSession.RouteChangeReason
            
            Task { @MainActor in
                guard let self = self else { return }
                // Create a new notification with only the data we need
                if let reason = routeChangeReason {
                    let newUserInfo: [String: Any] = [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
                    let newNotification = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: newUserInfo)
                    self.handleRouteChange(newNotification)
                    if reason == .newDeviceAvailable {
                        // Prefer Bluetooth HFP when it becomes available
                        await self.autoSelectBestInput()
                    }
                }
            }
        }
    }
    
    private func removeNotificationObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Notification Handlers
    
    func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            EnhancedLogger.shared.logAudioSessionInterruption(type)
            // Audio session was interrupted (e.g., phone call)
            // Recording will be automatically paused by the system
            
        case .ended:
            EnhancedLogger.shared.logAudioSessionInterruption(type)
            // Attempt to restore audio session
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.restoreAudioSession()
                    EnhancedLogger.shared.logAudioSession("Audio session restored after interruption", level: .info)
                } catch {
                    EnhancedLogger.shared.logAudioSession("Failed to restore audio session after interruption: \(error.localizedDescription)", level: .error)
                    await EnhancedErrorHandler().handleAudioProcessingError(.audioSessionConfigurationFailed(error.localizedDescription), context: "Interruption Recovery")
                }
            }
            
        @unknown default:
            break
        }
    }
    
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            EnhancedLogger.shared.logAudioSessionRouteChange(reason)
            
        case .oldDeviceUnavailable:
            EnhancedLogger.shared.logAudioSessionRouteChange(reason)
            
        case .categoryChange:
            EnhancedLogger.shared.logAudioSessionRouteChange(reason)
            
        default:
            EnhancedLogger.shared.logAudioSession("Audio route changed: \(reason)", level: .info)
        }
    }

    // MARK: - Input Selection

    /// Selects Bluetooth HFP input if available, otherwise falls back to built-in mic
    @MainActor
    private func autoSelectBestInput() async {
        guard let inputs = session.availableInputs else { return }
        if let bluetoothHFP = inputs.first(where: { $0.portType == .bluetoothHFP }) {
            do { try session.setPreferredInput(bluetoothHFP) } catch { /* best-effort */ }
            return
        }
        if let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
            do { try session.setPreferredInput(builtInMic) } catch { /* best-effort */ }
        }
    }
}

// MARK: - Error Types

enum AudioProcessingError: Error, LocalizedError {
    case audioSessionConfigurationFailed(String)
    case backgroundRecordingNotPermitted
    case chunkingFailed(String)
    case iCloudSyncFailed(String)
    case backgroundProcessingFailed(String)
    case fileRelationshipError(String)
    case recordingFailed(String)
    case playbackFailed(String)
    case formatConversionFailed(String)
    case metadataExtractionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .audioSessionConfigurationFailed(let message):
            return "Audio session configuration failed: \(message)"
        case .backgroundRecordingNotPermitted:
            return "Background recording permission not granted. Please enable background audio in app settings."
        case .chunkingFailed(let message):
            return "Audio file chunking failed: \(message)"
        case .iCloudSyncFailed(let message):
            return "iCloud synchronization failed: \(message)"
        case .backgroundProcessingFailed(let message):
            return "Background processing failed: \(message)"
        case .fileRelationshipError(let message):
            return "File relationship error: \(message)"
        case .recordingFailed(let message):
            return "Audio recording failed: \(message)"
        case .playbackFailed(let message):
            return "Audio playback failed: \(message)"
        case .formatConversionFailed(let message):
            return "Audio format conversion failed: \(message)"
        case .metadataExtractionFailed(let message):
            return "Audio metadata extraction failed: \(message)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .audioSessionConfigurationFailed:
            return "Try restarting the app or check your device's audio settings."
        case .backgroundRecordingNotPermitted:
            return "Enable background app refresh for this app in Settings > General > Background App Refresh."
        case .chunkingFailed:
            return "Try recording a shorter audio file or check available storage space."
        case .iCloudSyncFailed:
            return "Check your internet connection and iCloud settings."
        case .backgroundProcessingFailed:
            return "Try processing the file again when the app is in the foreground."
        case .fileRelationshipError:
            return "Try refreshing the file list or restarting the app."
        case .recordingFailed:
            return "Check microphone permissions and try recording again."
        case .playbackFailed:
            return "Check audio output settings and try playing again."
        case .formatConversionFailed:
            return "Try a different audio format or check file integrity."
        case .metadataExtractionFailed:
            return "Try refreshing the file or check if the file is corrupted."
        }
    }
}