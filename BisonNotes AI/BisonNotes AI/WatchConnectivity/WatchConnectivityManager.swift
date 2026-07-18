//
//  WatchConnectivityManager.swift
//  BisonNotes AI (iOS)
//
//  Created by Claude on 8/17/25.
//

import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
@preconcurrency import WatchConnectivity
#endif
import Combine
#if canImport(UIKit)
import UIKit
#endif

#if targetEnvironment(macCatalyst) || os(macOS)
// MARK: - Mac Stub
/// Minimal stub for Mac (Catalyst and native) where WatchConnectivity is not available
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isWatchAppInstalled: Bool = false

    var onWatchSyncRecordingReceived: ((Data, WatchSyncRequest) -> Void)?
    var onWatchRecordingSyncCompleted: ((UUID, Bool) -> Void)?

    static let shared = WatchConnectivityManager()

    func confirmSyncComplete(recordingId: UUID, success: Bool, coreDataId: String? = nil) {}
}
#else
/// Manages WatchConnectivity session and communication with Apple Watch.
///
/// The watch delivers recordings as complete files via WCSession.transferFile.
/// This manager stages the file, verifies it, hands the audio to the app via
/// `onWatchSyncRecordingReceived`, and reports the outcome back to the watch
/// over a queued channel (transferUserInfo) so confirmations survive
/// unreachability.
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {

    // MARK: - Published Properties
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isWatchAppInstalled: Bool = false

    // MARK: - Private Properties
    private var session: WCSession? {
        didSet {
            if let session = session {
                session.delegate = self
            }
        }
    }
    private var cancellables = Set<AnyCancellable>()

    // Dedupe tracking: watch-side retries can deliver the same recording twice
    private var inFlightRecordingIds: Set<UUID> = []
    private var importBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private let processedRecordingIdsKey = "processedWatchRecordingIds"
    private let maxProcessedIdsRetained = 200

    // MARK: - File sync callbacks
    var onWatchSyncRecordingReceived: ((Data, WatchSyncRequest) -> Void)?
    var onWatchRecordingSyncCompleted: ((UUID, Bool) -> Void)?

    // MARK: - Singleton
    static let shared = WatchConnectivityManager()

    override init() {
        super.init()
        setupWatchConnectivity()
        setupNotificationObservers()
    }

    deinit {
        if let session = session {
            session.delegate = nil
        }
        self.session = nil
    }

    // MARK: - Setup Methods

    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            AppLog.shared.watchConnectivity("WatchConnectivity not supported on this device", level: .error)
            connectionState = .error
            return
        }

        let wcSession = WCSession.default
        self.session = wcSession
        wcSession.activate()

        AppLog.shared.watchConnectivity("iPhone WatchConnectivity session setup initiated - activating...")
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppBecameActive()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateConnectionState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Receiving Recordings

    /// Handle completed file transfer from watch (file already staged by the
    /// delegate; the staged copy is cleaned up by the caller)
    private func handleWatchRecordingReceived(fileURL: URL, metadata: [String: Any]) {
        guard let recordingIdString = metadata["recordingId"] as? String,
              let recordingId = UUID(uuidString: recordingIdString) else {
            AppLog.shared.watchConnectivity("Received file but no recording ID in metadata", level: .error)
            return
        }

        // Dedupe: a retried transfer of an already-imported recording gets
        // re-acked so the watch can clean up, but is not imported again.
        if isRecordingAlreadyProcessed(recordingId) {
            AppLog.shared.watchConnectivity("Recording \(recordingId) already imported - re-acking instead of re-importing", level: .debug)
            sendQueuedSyncMessage(.syncComplete, info: [
                "recordingId": recordingId.uuidString,
                "confirmed": true,
                "timestamp": Date().timeIntervalSince1970
            ])
            return
        }

        guard !inFlightRecordingIds.contains(recordingId) else {
            AppLog.shared.watchConnectivity("Recording \(recordingId) import already in flight - ignoring duplicate", level: .debug)
            return
        }

        guard let filename = metadata["filename"] as? String,
              let duration = metadata["duration"] as? TimeInterval,
              let fileSize = metadata["fileSize"] as? Int64,
              let createdAtTimestamp = metadata["createdAt"] as? TimeInterval else {
            AppLog.shared.watchConnectivity("Insufficient metadata to build sync request", level: .error)
            return
        }

        inFlightRecordingIds.insert(recordingId)

        // Keep the app alive while the import runs, even if backgrounded
        // (the system may have launched us in the background for this file).
        // Ended in cleanupSyncOperation once the outcome is known.
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatchFileProcessing") { [weak self] in
            AppLog.shared.watchConnectivity("Background task expired during watch file processing", level: .error)
            Task { @MainActor in
                self?.endImportBackgroundTask(recordingId)
            }
        }
        importBackgroundTasks[recordingId] = backgroundTaskID

        let locationData = (metadata["locationData"] as? [String: Any]).flatMap {
            WatchLocationData.fromDictionary($0)
        }

        let syncRequest = WatchSyncRequest(
            recordingId: recordingId,
            filename: filename,
            duration: duration,
            fileSize: fileSize,
            createdAt: Date(timeIntervalSince1970: createdAtTimestamp),
            checksumMD5: metadata["checksumMD5"] as? String ?? "",
            locationData: locationData
        )

        let receivedSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let fileSizeMB = Double(receivedSize) / (1024 * 1024)
        AppLog.shared.watchConnectivity("Received recording file (\(String(format: "%.1f", fileSizeMB)) MB)")

        do {
            // Read the audio data
            let audioData = try Data(contentsOf: fileURL)

            // Verify checksum if provided
            if !syncRequest.checksumMD5.isEmpty {
                let actualChecksum = audioData.md5
                if actualChecksum != syncRequest.checksumMD5 {
                    AppLog.shared.watchConnectivity("Checksum mismatch for recording", level: .error)
                    handleSyncFailure(recordingId, reason: "checksum_mismatch")
                    return
                }
            }

            if let retryCount = metadata["retryCount"] as? Int, retryCount > 1 {
                AppLog.shared.watchConnectivity("Processing retried transfer (attempt #\(retryCount))", level: .debug)
            }

            // Create Core Data entry via callback
            if let callback = onWatchSyncRecordingReceived {
                callback(audioData, syncRequest)
                // Outcome is reported via confirmSyncComplete
            } else {
                AppLog.shared.watchConnectivity("onWatchSyncRecordingReceived callback is nil - file will not be processed", level: .error)
                handleSyncFailure(recordingId, reason: "callback_not_set")
            }

        } catch {
            AppLog.shared.watchConnectivity("Failed to read received file: \(error.localizedDescription)", level: .error)
            handleSyncFailure(recordingId, reason: "file_read_error")
        }
    }

    /// Confirm sync completion to watch
    func confirmSyncComplete(recordingId: UUID, success: Bool, coreDataId: String? = nil) {
        if success {
            AppLog.shared.watchConnectivity("Sync completed successfully for: \(recordingId)")

            // Remember this recording so duplicate deliveries are re-acked,
            // not re-imported
            markRecordingProcessed(recordingId)

            var confirmationInfo: [String: Any] = [
                "recordingId": recordingId.uuidString,
                "confirmed": true,
                "timestamp": Date().timeIntervalSince1970
            ]

            if let coreDataId = coreDataId {
                confirmationInfo["coreDataId"] = coreDataId
            }

            // Deliver via a queued channel so the confirmation survives the
            // watch being unreachable; lost confirmations would strand files
            // on the watch.
            sendQueuedSyncMessage(.syncComplete, info: confirmationInfo)

            cleanupSyncOperation(recordingId)

        } else {
            handleSyncFailure(recordingId, reason: "core_data_error")
        }
    }

    private func handleSyncFailure(_ recordingId: UUID, reason: String) {
        AppLog.shared.watchConnectivity("Sync failed for: \(recordingId), reason: \(reason)", level: .error)

        // Send failure message to watch via the queued channel
        sendQueuedSyncMessage(.syncFailed, info: [
            "recordingId": recordingId.uuidString,
            "reason": reason,
            "timestamp": Date().timeIntervalSince1970
        ])

        cleanupSyncOperation(recordingId)
    }

    private func cleanupSyncOperation(_ recordingId: UUID) {
        inFlightRecordingIds.remove(recordingId)
        endImportBackgroundTask(recordingId)
    }

    private func endImportBackgroundTask(_ recordingId: UUID) {
        if let taskID = importBackgroundTasks.removeValue(forKey: recordingId), taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    /// Send a sync outcome message via transferUserInfo, which queues for
    /// delivery when the watch is unreachable (unlike sendMessage).
    private func sendQueuedSyncMessage(_ message: WatchRecordingMessage, info: [String: Any]) {
        guard let session = session, session.activationState == .activated else {
            AppLog.shared.watchConnectivity("Cannot queue sync message - session not available", level: .error)
            return
        }

        var userInfo = message.userInfo
        userInfo.merge(info) { _, new in new }
        session.transferUserInfo(userInfo)
        AppLog.shared.watchConnectivity("Queued sync message for watch: \(message.rawValue)", level: .debug)
    }

    // MARK: - Processed Recording Tracking

    private func isRecordingAlreadyProcessed(_ recordingId: UUID) -> Bool {
        let processed = UserDefaults.standard.stringArray(forKey: processedRecordingIdsKey) ?? []
        return processed.contains(recordingId.uuidString)
    }

    private func markRecordingProcessed(_ recordingId: UUID) {
        var processed = UserDefaults.standard.stringArray(forKey: processedRecordingIdsKey) ?? []
        guard !processed.contains(recordingId.uuidString) else { return }

        processed.append(recordingId.uuidString)
        if processed.count > maxProcessedIdsRetained {
            processed.removeFirst(processed.count - maxProcessedIdsRetained)
        }
        UserDefaults.standard.set(processed, forKey: processedRecordingIdsKey)
    }

    // MARK: - Outgoing Messages

    /// Send a message to the watch (requires reachability)
    func sendRecordingCommand(_ message: WatchRecordingMessage, additionalInfo: [String: Any]? = nil) {
        guard let session = session, session.activationState == .activated, session.isReachable else {
            AppLog.shared.watchConnectivity("Cannot send command - watch not reachable or session not activated", level: .error)
            return
        }

        session.sendRecordingMessage(message, userInfo: additionalInfo)
        AppLog.shared.watchConnectivity("Sent command to watch: \(message.rawValue)", level: .debug)
    }

    // MARK: - App Lifecycle Handlers

    private func handleAppBecameActive() {
        // Let the watch know the phone app is active; the watch uses this to
        // re-enqueue any pending recordings
        sendRecordingCommand(.phoneAppActivated)
        updateConnectionState()
    }

    private func updateConnectionState() {
        guard let session = session else {
            connectionState = .error
            return
        }

        if !session.isPaired {
            connectionState = .disconnected
            isWatchAppInstalled = false
        } else if !session.isWatchAppInstalled {
            connectionState = .disconnected
            isWatchAppInstalled = false
        } else if !session.isReachable {
            connectionState = .phoneAppInactive
            isWatchAppInstalled = true
        } else {
            connectionState = .connected
            isWatchAppInstalled = true
        }
    }

    // MARK: - Message Processing

    private func processWatchMessage(_ message: [String: Any]) {
        guard let messageTypeString = message["messageType"] as? String,
              let messageType = WatchRecordingMessage(rawValue: messageTypeString) else {
            AppLog.shared.watchConnectivity("Unknown or missing message type from watch: \(message["messageType"] ?? "nil")", level: .error)
            return
        }

        switch messageType {
        case .errorOccurred:
            if let errorMessage = WatchErrorMessage.fromDictionary(message) {
                AppLog.shared.watchConnectivity("Received error from watch: \(errorMessage.message)", level: .error)
            }

        case .watchAppActivated:
            AppLog.shared.watchConnectivity("Watch app activated")
            connectionState = .connected

        case .requestSync:
            AppLog.shared.watchConnectivity("Watch requested sync", level: .debug)

        case .connectionStatusUpdate:
            updateConnectionState()

        // Sent by iPhone, not received
        case .phoneAppActivated, .syncComplete, .syncFailed:
            break
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                AppLog.shared.watchConnectivity("WCSession activation failed: \(error.localizedDescription)", level: .error)
                self.connectionState = .error
                return
            }

            switch activationState {
            case .activated:
                AppLog.shared.watchConnectivity("iPhone WCSession activated successfully")
                self.updateConnectionState()
            case .inactive:
                AppLog.shared.watchConnectivity("WCSession inactive", level: .debug)
                self.connectionState = .disconnected
            case .notActivated:
                AppLog.shared.watchConnectivity("WCSession not activated", level: .error)
                self.connectionState = .error
            @unknown default:
                AppLog.shared.watchConnectivity("WCSession unknown activation state", level: .error)
                self.connectionState = .error
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            AppLog.shared.watchConnectivity("WCSession became inactive", level: .debug)
            self.connectionState = .disconnected
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async {
            AppLog.shared.watchConnectivity("WCSession deactivated", level: .debug)
            self.connectionState = .disconnected
        }

        // Reactivate session
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            AppLog.shared.watchConnectivity("Watch reachability changed: \(session.isReachable)", level: .debug)
            self.updateConnectionState()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.processWatchMessage(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.processWatchMessage(message)

            // Send reply with current phone status
            let reply: [String: Any] = [
                "status": "received",
                "phoneAppActive": true,
                "timestamp": Date().timeIntervalSince1970
            ]
            replyHandler(reply)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            AppLog.shared.watchConnectivity("Received application context from watch", level: .debug)
            self.processWatchMessage(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            AppLog.shared.watchConnectivity("Received user info from watch", level: .debug)
            self.processWatchMessage(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            AppLog.shared.watchConnectivity("User info transfer failed: \(error.localizedDescription)", level: .error)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        AppLog.shared.watchConnectivity("Received file from watch")

        let metadata = file.metadata ?? [:]

        guard let transferType = metadata["transferType"] as? String else {
            AppLog.shared.watchConnectivity("Received file transfer without transfer type - ignoring", level: .error)
            return
        }

        guard transferType == "complete_recording" || transferType == "reliable_recording" else {
            AppLog.shared.watchConnectivity("Unknown transfer type: \(transferType)", level: .error)
            return
        }

        // The system deletes file.fileURL as soon as this delegate method returns,
        // so the file must be moved to a staging location synchronously, before
        // any async processing.
        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("WatchTransferStaging", isDirectory: true)
        let stagedURL = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(file.fileURL.lastPathComponent)")

        do {
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try fileManager.moveItem(at: file.fileURL, to: stagedURL)
        } catch {
            AppLog.shared.watchConnectivity("Failed to stage received watch file: \(error.localizedDescription)", level: .error)
            return
        }

        DispatchQueue.main.async {
            self.handleWatchRecordingReceived(fileURL: stagedURL, metadata: metadata)
            try? FileManager.default.removeItem(at: stagedURL)
        }
    }
}
#endif // !targetEnvironment(macCatalyst)

// MARK: - Extensions

import CryptoKit

extension Data {
    var md5: String {
        let digest = Insecure.MD5.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
