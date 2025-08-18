//
//  WatchRecordingMessage.swift
//  BisonNotes AI
//
//  Created by Claude on 8/17/25.
//

import Foundation
import WatchConnectivity

/// Messages sent between watch and phone for recording coordination
enum WatchRecordingMessage: String, CaseIterable, Codable {
    // Recording control commands
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case pauseRecording = "pause_recording"
    case resumeRecording = "resume_recording"
    
    // Status updates
    case recordingStatusUpdate = "recording_status_update"
    case connectionStatusUpdate = "connection_status_update"
    case errorOccurred = "error_occurred"
    
    // Audio data transfer
    case audioChunkTransfer = "audio_chunk_transfer"
    case audioTransferComplete = "audio_transfer_complete"
    case chunkAcknowledgment = "chunkAcknowledgment"
    
    // App lifecycle
    case phoneAppActivated = "phone_app_activated"
    case watchAppActivated = "watch_app_activated"
    case requestPhoneAppActivation = "request_phone_app_activation"
    case requestSync = "request_sync"
    
    var userInfo: [String: Any] {
        return ["messageType": self.rawValue]
    }
}

/// Data structure for recording status updates
struct WatchRecordingStatusUpdate: Codable {
    let state: WatchRecordingState
    let recordingTime: TimeInterval
    let timestamp: Date
    let batteryLevel: Float?
    let errorMessage: String?
    
    init(state: WatchRecordingState, recordingTime: TimeInterval, batteryLevel: Float? = nil, errorMessage: String? = nil) {
        self.state = state
        self.recordingTime = recordingTime
        self.timestamp = Date()
        self.batteryLevel = batteryLevel
        self.errorMessage = errorMessage
    }
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "state": state.rawValue,
            "recordingTime": recordingTime,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        
        if let batteryLevel = batteryLevel {
            dict["batteryLevel"] = batteryLevel
        }
        
        if let errorMessage = errorMessage {
            dict["errorMessage"] = errorMessage
        }
        
        return dict
    }
    
    static func fromDictionary(_ dict: [String: Any]) -> WatchRecordingStatusUpdate? {
        guard let stateRaw = dict["state"] as? String,
              let state = WatchRecordingState(rawValue: stateRaw),
              let recordingTime = dict["recordingTime"] as? TimeInterval else {
            return nil
        }
        
        let batteryLevel = dict["batteryLevel"] as? Float
        let errorMessage = dict["errorMessage"] as? String
        
        return WatchRecordingStatusUpdate(
            state: state,
            recordingTime: recordingTime,
            batteryLevel: batteryLevel,
            errorMessage: errorMessage
        )
    }
}

/// Data structure for error messages
struct WatchErrorMessage: Codable {
    let errorType: WatchErrorType
    let message: String
    let timestamp: Date
    let deviceType: WatchDeviceType
    
    init(errorType: WatchErrorType, message: String, deviceType: WatchDeviceType) {
        self.errorType = errorType
        self.message = message
        self.timestamp = Date()
        self.deviceType = deviceType
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "errorType": errorType.rawValue,
            "message": message,
            "timestamp": timestamp.timeIntervalSince1970,
            "deviceType": deviceType.rawValue
        ]
    }
    
    static func fromDictionary(_ dict: [String: Any]) -> WatchErrorMessage? {
        guard let errorTypeRaw = dict["errorType"] as? String,
              let errorType = WatchErrorType(rawValue: errorTypeRaw),
              let message = dict["message"] as? String,
              let deviceTypeRaw = dict["deviceType"] as? String,
              let deviceType = WatchDeviceType(rawValue: deviceTypeRaw) else {
            return nil
        }
        
        return WatchErrorMessage(errorType: errorType, message: message, deviceType: deviceType)
    }
}

/// Types of errors that can occur during watch-phone communication
enum WatchErrorType: String, Codable, CaseIterable {
    case audioRecordingFailed = "audio_recording_failed"
    case connectionLost = "connection_lost"
    case batteryTooLow = "battery_too_low"
    case storageInsufficient = "storage_insufficient"
    case permissionDenied = "permission_denied"
    case phoneAppNotResponding = "phone_app_not_responding"
    case watchAppNotResponding = "watch_app_not_responding"
    case audioTransferFailed = "audio_transfer_failed"
    case unknownError = "unknown_error"
}

/// Device type identifier for error reporting
enum WatchDeviceType: String, Codable, CaseIterable {
    case iPhone = "iPhone"
    case appleWatch = "Apple Watch"
}

/// Extension to simplify WatchConnectivity message sending
extension WCSession {
    /// Send a recording message with optional user info
    func sendRecordingMessage(_ message: WatchRecordingMessage, userInfo: [String: Any]? = nil) {
        guard isReachable else {
            print("⌚ WCSession not reachable, cannot send message: \(message.rawValue)")
            return
        }
        
        var finalUserInfo = message.userInfo
        if let additionalInfo = userInfo {
            finalUserInfo.merge(additionalInfo) { _, new in new }
        }
        
        sendMessage(finalUserInfo, replyHandler: nil) { error in
            print("❌ Failed to send watch message \(message.rawValue): \(error.localizedDescription)")
        }
    }
    
    /// Send a status update message
    func sendStatusUpdate(_ statusUpdate: WatchRecordingStatusUpdate) {
        sendRecordingMessage(.recordingStatusUpdate, userInfo: statusUpdate.toDictionary())
    }
    
    /// Send an error message
    func sendErrorMessage(_ errorMessage: WatchErrorMessage) {
        sendRecordingMessage(.errorOccurred, userInfo: errorMessage.toDictionary())
    }
}