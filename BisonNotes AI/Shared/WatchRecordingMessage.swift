//
//  WatchRecordingMessage.swift
//  BisonNotes AI
//
//  Created by Claude on 8/17/25.
//

import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
import CoreLocation

/// Messages sent between watch and phone for recording coordination.
///
/// Audio itself is delivered via WCSession.transferFile (see the reliable
/// transfer system in the watch app); these messages cover lifecycle pings
/// and sync outcome notifications.
enum WatchRecordingMessage: String, CaseIterable, Codable {
    // Status updates
    case connectionStatusUpdate = "connection_status_update"
    case errorOccurred = "error_occurred"

    // App lifecycle
    case phoneAppActivated = "phone_app_activated"
    case watchAppActivated = "watch_app_activated"
    case requestSync = "request_sync"

    // Sync outcomes (sent from iPhone via queued transferUserInfo)
    case syncComplete = "sync_complete"
    case syncFailed = "sync_failed"

    var userInfo: [String: Any] {
        return ["messageType": self.rawValue]
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

#if canImport(WatchConnectivity)
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
}
#endif

/// Data structure for sync request
struct WatchSyncRequest: Codable {
    let recordingId: UUID
    let filename: String
    let duration: TimeInterval
    let fileSize: Int64
    let createdAt: Date
    let checksumMD5: String
    let timestamp: Date
    let locationData: WatchLocationData?
    
    init(recordingId: UUID, filename: String, duration: TimeInterval, fileSize: Int64, createdAt: Date, checksumMD5: String, locationData: WatchLocationData? = nil) {
        self.recordingId = recordingId
        self.filename = filename
        self.duration = duration
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.checksumMD5 = checksumMD5
        self.timestamp = Date()
        self.locationData = locationData
    }
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "recordingId": recordingId.uuidString,
            "filename": filename,
            "duration": duration,
            "fileSize": fileSize,
            "createdAt": createdAt.timeIntervalSince1970,
            "checksumMD5": checksumMD5,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        
        if let locationData = locationData {
            dict["locationData"] = locationData.toDictionary()
        }
        
        return dict
    }
    
    static func fromDictionary(_ dict: [String: Any]) -> WatchSyncRequest? {
        guard let recordingIdString = dict["recordingId"] as? String,
              let recordingId = UUID(uuidString: recordingIdString),
              let filename = dict["filename"] as? String,
              let duration = dict["duration"] as? TimeInterval,
              let fileSize = dict["fileSize"] as? Int64,
              let createdAtInterval = dict["createdAt"] as? TimeInterval,
              let checksumMD5 = dict["checksumMD5"] as? String else {
            return nil
        }
        
        let locationData: WatchLocationData?
        if let locationDict = dict["locationData"] as? [String: Any] {
            locationData = WatchLocationData.fromDictionary(locationDict)
        } else {
            locationData = nil
        }
        
        return WatchSyncRequest(
            recordingId: recordingId,
            filename: filename,
            duration: duration,
            fileSize: fileSize,
            createdAt: Date(timeIntervalSince1970: createdAtInterval),
            checksumMD5: checksumMD5,
            locationData: locationData
        )
    }
}

/// Data structure for location data from watch recordings
struct WatchLocationData: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let accuracy: Double?
    
    init(latitude: Double, longitude: Double, timestamp: Date, accuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.accuracy = accuracy
    }
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        
        if let accuracy = accuracy {
            dict["accuracy"] = accuracy
        }
        
        return dict
    }
    
    static func fromDictionary(_ dict: [String: Any]) -> WatchLocationData? {
        guard let latitude = dict["latitude"] as? Double,
              let longitude = dict["longitude"] as? Double,
              let timestampInterval = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        
        let accuracy = dict["accuracy"] as? Double
        
        return WatchLocationData(
            latitude: latitude,
            longitude: longitude,
            timestamp: Date(timeIntervalSince1970: timestampInterval),
            accuracy: accuracy
        )
    }
    
    /// Convert to LocationData for use in iPhone app
    func toLocationData() -> LocationData {
        return LocationData(
            latitude: latitude,
            longitude: longitude,
            timestamp: timestamp,
            accuracy: accuracy,
            address: nil // Address will be resolved on iPhone
        )
    }
}

/// Shared location data structure - compatible with both iPhone and Watch apps
struct LocationData: Codable, Identifiable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let accuracy: Double?
    let address: String?
    
    init(location: CLLocation) {
        self.id = UUID()
        // Ensure coordinates are valid and not NaN
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        self.latitude = (lat.isFinite && !lat.isNaN) ? lat : 0.0
        self.longitude = (lng.isFinite && !lng.isNaN) ? lng : 0.0
        self.timestamp = location.timestamp
        
        // Validate accuracy - negative accuracy means invalid
        let acc = location.horizontalAccuracy
        self.accuracy = (acc >= 0 && acc.isFinite && !acc.isNaN) ? acc : nil
        
        // Address will be set later through reverse geocoding
        self.address = nil
    }
    
    init(id: UUID = UUID(), latitude: Double, longitude: Double, timestamp: Date, accuracy: Double?, address: String?) {
        self.id = id
        // Ensure coordinates are valid and not NaN
        self.latitude = (latitude.isFinite && !latitude.isNaN) ? latitude : 0.0
        self.longitude = (longitude.isFinite && !longitude.isNaN) ? longitude : 0.0
        self.timestamp = timestamp
        // Ensure accuracy is valid if provided
        if let accuracy = accuracy {
            self.accuracy = (accuracy.isFinite && !accuracy.isNaN && accuracy >= 0) ? accuracy : nil
        } else {
            self.accuracy = nil
        }
        self.address = address
    }
    
    init(latitude: Double, longitude: Double, timestamp: Date = Date(), accuracy: Double? = nil, address: String? = nil) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.accuracy = accuracy
        self.address = address
    }
    
    /// Formatted coordinate string for display
    var coordinateString: String {
        let safeLat = latitude.isFinite && !latitude.isNaN ? latitude : 0.0
        let safeLng = longitude.isFinite && !longitude.isNaN ? longitude : 0.0
        return String(format: "%.6f, %.6f", safeLat, safeLng)
    }
    
    /// Formatted address with fallback to coordinates
    var formattedAddress: String {
        return address ?? "Location: \(coordinateString)"
    }
    
    /// Display location with address preference
    var displayLocation: String {
        if let address = address, !address.isEmpty {
            return address
        }
        return coordinateString
    }
}