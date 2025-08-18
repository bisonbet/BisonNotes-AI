//
//  WatchRecordingState.swift
//  BisonNotes AI
//
//  Created by Claude on 8/17/25.
//

import Foundation

/// Recording states that can be synchronized between watch and phone
enum WatchRecordingState: String, CaseIterable, Codable {
    case idle = "idle"
    case recording = "recording"
    case paused = "paused"
    case stopping = "stopping"
    case processing = "processing"
    case error = "error"
    
    /// Human-readable description of the state
    var description: String {
        switch self {
        case .idle:
            return "Ready to record"
        case .recording:
            return "Recording"
        case .paused:
            return "Paused"
        case .stopping:
            return "Stopping"
        case .processing:
            return "Processing"
        case .error:
            return "Error occurred"
        }
    }
    
    /// Whether recording is actively capturing audio
    var isActivelyRecording: Bool {
        return self == .recording
    }
    
    /// Whether the recording session is in progress (including paused)
    var isRecordingSession: Bool {
        return self == .recording || self == .paused
    }
    
    /// Whether the state allows for starting a new recording
    var canStartRecording: Bool {
        return self == .idle
    }
    
    /// Whether the state allows for pausing
    var canPause: Bool {
        return self == .recording
    }
    
    /// Whether the state allows for resuming
    var canResume: Bool {
        return self == .paused
    }
    
    /// Whether the state allows for stopping
    var canStop: Bool {
        return self == .recording || self == .paused
    }
    
    /// Color representation for UI display
    var displayColor: String {
        switch self {
        case .idle:
            return "green"
        case .recording:
            return "red"
        case .paused:
            return "yellow"
        case .stopping:
            return "orange"
        case .processing:
            return "blue"
        case .error:
            return "red"
        }
    }
    
    /// SF Symbol name for UI display
    var sfSymbolName: String {
        switch self {
        case .idle:
            return "record.circle"
        case .recording:
            return "stop.circle.fill"
        case .paused:
            return "play.circle"
        case .stopping:
            return "stop.circle"
        case .processing:
            return "gearshape.circle"
        case .error:
            return "exclamationmark.circle"
        }
    }
}

/// Connection states between watch and phone
enum WatchConnectionState: String, CaseIterable, Codable {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case phoneAppInactive = "phone_app_inactive"
    case watchAppInactive = "watch_app_inactive"
    case error = "error"
    
    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .phoneAppInactive:
            return "Phone app inactive"
        case .watchAppInactive:
            return "Watch app inactive"
        case .error:
            return "Connection error"
        }
    }
    
    var isConnected: Bool {
        return self == .connected
    }
    
    var sfSymbolName: String {
        switch self {
        case .disconnected:
            return "phone.connection"
        case .connecting:
            return "phone.connection"
        case .connected:
            return "phone.fill.connection"
        case .phoneAppInactive:
            return "iphone.slash"
        case .watchAppInactive:
            return "applewatch.slash"
        case .error:
            return "wifi.exclamationmark"
        }
    }
}

/// Battery level categories for power management
enum WatchBatteryLevel: String, CaseIterable, Codable {
    case critical = "critical"    // < 10%
    case low = "low"             // 10-20%
    case medium = "medium"       // 20-50%
    case good = "good"           // 50-80%
    case excellent = "excellent" // > 80%
    
    init(batteryLevel: Float) {
        switch batteryLevel {
        case 0.0..<0.1:
            self = .critical
        case 0.1..<0.2:
            self = .low
        case 0.2..<0.5:
            self = .medium
        case 0.5..<0.8:
            self = .good
        default:
            self = .excellent
        }
    }
    
    var shouldLimitRecording: Bool {
        return self == .critical || self == .low
    }
    
    var maxRecordingDuration: TimeInterval {
        switch self {
        case .critical:
            return 60 // 1 minute
        case .low:
            return 300 // 5 minutes
        case .medium:
            return 600 // 10 minutes
        case .good:
            return 1800 // 30 minutes
        case .excellent:
            return 3600 // 1 hour
        }
    }
    
    var description: String {
        switch self {
        case .critical:
            return "Critical"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .good:
            return "Good"
        case .excellent:
            return "Excellent"
        }
    }
}