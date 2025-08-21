//
//  WatchFeedbackManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/18/25.
//

import Foundation
import SwiftUI

#if canImport(WatchKit)
import WatchKit
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Manages haptic and audio feedback for the watch app
@MainActor
class WatchFeedbackManager: ObservableObject {
    
    // MARK: - Feedback Types
    
    enum FeedbackType {
        case recordingStarted
        case recordingStopped
        case recordingPaused
        case recordingResumed
        case connectionEstablished
        case connectionLost
        case transferStarted
        case transferCompleted
        case transferFailed
        case lowBattery
        case error
        case success
    }
    
    // MARK: - Properties
    
    @Published var isAudioFeedbackEnabled: Bool = true
    @Published var isHapticFeedbackEnabled: Bool = true
    
    private var audioPlayer: AVAudioPlayer?
    
    // MARK: - Public Interface
    
    /// Provide feedback for a specific event
    func provideFeedback(for type: FeedbackType) {
        if isHapticFeedbackEnabled {
            provideHapticFeedback(for: type)
        }
        
        if isAudioFeedbackEnabled {
            provideAudioFeedback(for: type)
        }
    }
    
    /// Enable or disable audio feedback based on user preference
    func setAudioFeedbackEnabled(_ enabled: Bool) {
        isAudioFeedbackEnabled = enabled
    }
    
    /// Enable or disable haptic feedback based on user preference
    func setHapticFeedbackEnabled(_ enabled: Bool) {
        isHapticFeedbackEnabled = enabled
    }
    
    // MARK: - Haptic Feedback
    
    private func provideHapticFeedback(for type: FeedbackType) {
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        
        switch type {
        case .recordingStarted:
            // Strong start pattern
            device.play(.start)
            
        case .recordingStopped:
            // Strong stop pattern
            device.play(.stop)
            
        case .recordingPaused:
            // Double tap pattern for pause
            device.play(.directionUp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                device.play(.directionDown)
            }
            
        case .recordingResumed:
            // Single strong tap for resume
            device.play(.success)
            
        case .connectionEstablished:
            // Success pattern
            device.play(.success)
            
        case .connectionLost:
            // Warning pattern
            device.play(.failure)
            
        case .transferStarted:
            // Light notification
            device.play(.notification)
            
        case .transferCompleted:
            // Success pattern
            device.play(.success)
            
        case .transferFailed:
            // Failure pattern
            device.play(.failure)
            
        case .lowBattery:
            // Triple warning taps
            device.play(.failure)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                device.play(.failure)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    device.play(.failure)
                }
            }
            
        case .error:
            // Strong failure pattern
            device.play(.failure)
            
        case .success:
            // Success pattern
            device.play(.success)
        }
        #endif
    }
    
    // MARK: - Audio Feedback
    
    private func provideAudioFeedback(for type: FeedbackType) {
        // Only provide audio feedback if not in silent mode
        guard !isSilentModeEnabled() else { return }
        
        let soundName: String?
        
        switch type {
        case .recordingStarted:
            soundName = "record_start"
        case .recordingStopped:
            soundName = "record_stop"
        case .recordingPaused:
            soundName = "record_pause"
        case .recordingResumed:
            soundName = "record_resume"
        case .connectionEstablished:
            soundName = "connection_success"
        case .connectionLost:
            soundName = "connection_lost"
        case .transferCompleted:
            soundName = "transfer_success"
        case .transferFailed, .error:
            soundName = "error"
        case .success:
            soundName = "success"
        default:
            soundName = nil
        }
        
        if let soundName = soundName {
            playSystemSound(named: soundName)
        }
    }
    
    private func playSystemSound(named soundName: String) {
        #if canImport(AVFoundation)
        // For now, use system sounds. In production, you could add custom sound files
        // to the watch app bundle and play them here
        
        // Use WKInterfaceDevice for system sounds instead
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        
        // Map sound names to WatchKit haptic types as a fallback
        switch soundName {
        case "record_start":
            device.play(.start)
        case "record_stop":
            device.play(.stop)
        case "success", "transfer_success", "connection_success":
            device.play(.success)
        case "error", "transfer_failed", "connection_lost":
            device.play(.failure)
        default:
            device.play(.notification)
        }
        #endif
        #endif
    }
    
    private func isSilentModeEnabled() -> Bool {
        // Check if device is in silent mode
        // On watchOS, we can assume audio feedback should be minimal
        // and rely more on haptic feedback
        return true // Default to silent for watch
    }
    
    // MARK: - Visual Feedback Helpers
    
    /// Get color for feedback type (for visual feedback integration)
    func getColor(for type: FeedbackType) -> Color {
        switch type {
        case .recordingStarted, .recordingResumed, .success, .connectionEstablished, .transferCompleted:
            return .green
        case .recordingStopped:
            return .red
        case .recordingPaused:
            return .orange
        case .transferStarted:
            return .blue
        case .connectionLost, .transferFailed, .error, .lowBattery:
            return .red
        }
    }
    
    /// Get SF Symbol for feedback type (for visual feedback integration)
    func getSymbol(for type: FeedbackType) -> String {
        switch type {
        case .recordingStarted:
            return "record.circle.fill"
        case .recordingStopped:
            return "stop.circle.fill"
        case .recordingPaused:
            return "pause.circle.fill"
        case .recordingResumed:
            return "play.circle.fill"
        case .connectionEstablished:
            return "iphone"
        case .connectionLost:
            return "iphone.slash"
        case .transferStarted:
            return "arrow.up.circle"
        case .transferCompleted:
            return "checkmark.circle.fill"
        case .transferFailed:
            return "xmark.circle.fill"
        case .lowBattery:
            return "battery.0"
        case .error:
            return "exclamationmark.triangle.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }
}

// MARK: - Convenience Extensions

extension WatchFeedbackManager {
    
    /// Provide feedback for recording state changes
    func feedbackForRecordingStateChange(from oldState: WatchRecordingState, to newState: WatchRecordingState) {
        switch newState {
        case .recording:
            if oldState == .paused {
                provideFeedback(for: .recordingResumed)
            } else {
                provideFeedback(for: .recordingStarted)
            }
        case .paused:
            provideFeedback(for: .recordingPaused)
        case .idle:
            if oldState.isRecordingSession {
                provideFeedback(for: .recordingStopped)
            }
        case .error:
            provideFeedback(for: .error)
        case .processing:
            provideFeedback(for: .transferStarted)
        case .stopping:
            // No specific feedback for stopping state
            break
        }
    }
    
    /// Provide feedback for connection state changes
    func feedbackForConnectionStateChange(from oldState: WatchConnectionState, to newState: WatchConnectionState) {
        switch newState {
        case .connected:
            if oldState != .connected {
                provideFeedback(for: .connectionEstablished)
            }
        case .disconnected, .error:
            if oldState.isConnected {
                provideFeedback(for: .connectionLost)
            }
        default:
            break
        }
    }
    
    /// Provide feedback for transfer progress
    func feedbackForTransferProgress(completed: Bool, failed: Bool = false) {
        if failed {
            provideFeedback(for: .transferFailed)
        } else if completed {
            provideFeedback(for: .transferCompleted)
        }
    }
    
    /// Provide feedback for battery level
    func feedbackForBatteryLevel(_ level: Float) {
        if level <= 0.10 { // 10% or less
            provideFeedback(for: .lowBattery)
        }
    }
}