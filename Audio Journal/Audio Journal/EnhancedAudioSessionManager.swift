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
@MainActor
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
            mode: .default,
            options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker],
            allowMixedAudio: true,
            backgroundRecording: false
        )
        
        static let backgroundRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker],
            allowMixedAudio: true,
            backgroundRecording: true
        )
        
        static let standardRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP],
            allowMixedAudio: false,
            backgroundRecording: false
        )
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupNotificationObservers()
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
            Task { @MainActor in
                self?.handleAudioInterruption(notification)
            }
        }
        
        // Route change observer
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
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
            print("🔇 Audio interruption began")
            // Audio session was interrupted (e.g., phone call)
            // Recording will be automatically paused by the system
            
        case .ended:
            print("🔊 Audio interruption ended")
            // Attempt to restore audio session
            Task {
                do {
                    try await restoreAudioSession()
                } catch {
                    print("❌ Failed to restore audio session after interruption: \(error)")
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
            print("🎧 New audio device available")
            
        case .oldDeviceUnavailable:
            print("🎧 Audio device disconnected")
            
        case .categoryChange:
            print("🔄 Audio category changed")
            
        default:
            print("🔄 Audio route changed: \(reason)")
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
        }
    }
}