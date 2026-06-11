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

