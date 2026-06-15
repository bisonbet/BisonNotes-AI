//
//  WatchConnectivityManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import Foundation
@preconcurrency import WatchConnectivity
import Combine
import CryptoKit

#if canImport(WatchKit)
import WatchKit
#endif

/// Manages WatchConnectivity session and communication with iPhone.
///
/// Recordings are delivered through the reliable transfer queue: every
/// completed recording becomes a `ReliableTransfer` backed by
/// `WCSession.transferFile` (which queues across unreachability and app
/// restarts). Local files are deleted only after the iPhone confirms the
/// recording was saved to Core Data.
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {

    // MARK: - Published Properties
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isPhoneAppActive: Bool = false
    @Published var isTransferringAudio: Bool = false
    @Published var audioTransferProgress: Double = 0.0

    /// Current recording state, kept up to date by WatchRecordingViewModel so
    /// connectivity work can be minimized while a recording is in progress.
    @Published var watchRecordingState: WatchRecordingState = .idle

    // MARK: - Private Properties
    private var session: WCSession? {
        didSet {
            if let session = session {
                session.delegate = self
            }
        }
    }
    private var cancellables = Set<AnyCancellable>()

    // File transfer tracking
    private var activeFileTransfers: [String: WCSessionFileTransfer] = [:]
    private var transferStartTimes: [String: Date] = [:]
    private var transferProgressObservations: [String: NSKeyValueObservation] = [:]

    // Reliable transfer system
    private var reliableTransfers: [UUID: ReliableTransfer] = [:]
    private var retryTimer: Timer?
    private let retryCheckInterval: TimeInterval = 30.0

    // Connectivity debouncing and throttling
    private var connectivityDebounceTimer: Timer?
    private let connectivityDebounceDelay: TimeInterval = 2.0
    private var lastSyncRequestTime: Date?
    private let minSyncRequestInterval: TimeInterval = 3.0
    private var isRecoveringConnection = false

    // MARK: - Callbacks for WatchRecordingViewModel integration
    var onPhoneAppActivated: (() -> Void)?
    var onPhoneErrorReceived: ((WatchErrorMessage) -> Void)?
    var onConnectionRestored: (() -> Void)?

    // MARK: - Singleton
    static let shared = WatchConnectivityManager()

    override init() {
        super.init()
        setupWatchConnectivity()
        setupNotificationObservers()
        loadReliableTransfers()
        startRetryTimer()
    }

    deinit {
        if let session = session {
            session.delegate = nil
        }
        self.session = nil
        retryTimer?.invalidate()
        connectivityDebounceTimer?.invalidate()
    }

    // MARK: - Setup Methods

    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            print("⌚ WatchConnectivity not supported on this device")
            connectionState = .error
            return
        }

        let wcSession = WCSession.default
        self.session = wcSession
        wcSession.activate()

        print("⌚ Watch WatchConnectivity session setup initiated")
    }

    private func setupNotificationObservers() {
        #if canImport(WatchKit)
        NotificationCenter.default.publisher(for: WKExtension.applicationDidBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleWatchAppBecameActive()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: WKExtension.applicationWillResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleWatchAppWillResignActive()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    // MARK: - Public Interface

    /// Send a message to the phone (requires reachability; file sync uses the
    /// reliable transfer queue instead)
    func sendRecordingCommand(_ message: WatchRecordingMessage, additionalInfo: [String: Any]? = nil) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot send command - session not available or not activated")
            return
        }

        session.sendRecordingMessage(message, userInfo: additionalInfo)
        print("⌚ Sent command to phone: \(message.rawValue)")
    }

    /// Request sync with phone app
    func requestSyncWithPhone() {
        guard let session = session, session.isReachable else {
            return
        }
        sendRecordingCommand(.requestSync)
    }

    // MARK: - App Lifecycle Handlers

    private func handleWatchAppBecameActive() {
        if isRecordingInProgress() {
            print("⌚ Watch app became active (recording in progress - minimal sync)")
            updateConnectionState()
        } else {
            print("⌚ Watch app became active (normal sync)")
            sendRecordingCommand(.watchAppActivated)
            requestSyncWithPhone()
            updateConnectionState()
        }
    }

    private func handleWatchAppWillResignActive() {
        if isRecordingInProgress() {
            print("⌚ Watch app will resign active (recording in progress - preserving session)")
            // Audio recording continues in the background; avoid heavy sync work
        } else {
            print("⌚ Watch app will resign active (normal)")
            updateConnectionState()
        }
    }

    /// Check if recording is currently in progress
    private func isRecordingInProgress() -> Bool {
        return watchRecordingState == .recording || watchRecordingState == .paused
    }

    private func updateConnectionState() {
        guard let session = session else {
            connectionState = .error
            return
        }

        let previousState = connectionState

        if !session.isReachable {
            connectionState = .phoneAppInactive
            isPhoneAppActive = false
        } else {
            connectionState = .connected
            isPhoneAppActive = true
        }

        if previousState != .connected && connectionState == .connected {
            handleConnectionRestored()
        }
    }

    /// Handle connection restoration - retry queued transfers
    private func handleConnectionRestored() {
        print("⌚ Connection restored, performing state recovery")

        guard !isRecoveringConnection else {
            print("⌚ Already recovering connection, skipping duplicate recovery")
            return
        }

        isRecoveringConnection = true

        onConnectionRestored?()

        // Retry reliable transfers
        retryReliableTransfers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.requestSyncWithPhoneThrottled()
            self?.isRecoveringConnection = false
        }
    }

    /// Handle connection loss - recording continues; transfers stay queued
    private func handleConnectionLost() {
        print("⌚ Connection to phone lost - queued transfers will resume when reconnected")
        isRecoveringConnection = false
    }

    // MARK: - Reliable Transfer System

    /// Transfer complete recording file to iPhone with reliability
    func transferCompleteRecording(fileURL: URL, metadata: WatchRecordingMetadata, completion: @escaping (Bool) -> Void) {
        if reliableTransfers[metadata.id] == nil {
            let reliableTransfer = ReliableTransfer(from: metadata, fileURL: fileURL)
            reliableTransfers[reliableTransfer.recordingId] = reliableTransfer
            saveReliableTransfers()
            print("⌚ Added reliable transfer: \(metadata.filename)")
        } else {
            print("⌚ Reliable transfer already queued for: \(metadata.filename)")
        }

        // Attempt immediate transfer if connected
        attemptReliableTransfer(metadata.id)

        // Always call completion - reliable system will handle the actual transfer
        completion(true)
    }

    /// Whether a reliable transfer is already queued for this recording
    func hasReliableTransfer(for recordingId: UUID) -> Bool {
        return reliableTransfers[recordingId] != nil
    }

    /// Attempt to transfer a specific reliable transfer
    private func attemptReliableTransfer(_ recordingId: UUID) {
        guard var transfer = reliableTransfers[recordingId] else {
            print("⚠️ Reliable transfer not found: \(recordingId)")
            return
        }

        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot attempt transfer - session not available")
            return
        }

        let transferKey = transfer.recordingId.uuidString

        // Skip if we already have this file in flight
        guard activeFileTransfers[transferKey] == nil else {
            print("⌚ File transfer already in flight for \(transfer.filename) - skipping")
            return
        }

        // Skip if WCSession still has this file queued at the OS level
        // (outstanding transfers survive app relaunches)
        if session.outstandingFileTransfers.contains(where: {
            ($0.file.metadata?["recordingId"] as? String) == transferKey
        }) {
            print("⌚ WCSession already has an outstanding transfer for \(transfer.filename) - skipping")
            return
        }

        guard FileManager.default.fileExists(atPath: transfer.fileURL.path) else {
            print("❌ Recording file no longer exists: \(transfer.filename)")
            transfer.recordFailure("file_not_found")
            reliableTransfers[recordingId] = transfer
            saveReliableTransfers()
            return
        }

        // Record attempt
        transfer.recordAttempt()
        reliableTransfers[recordingId] = transfer
        saveReliableTransfers()

        print("⌚ Attempting transfer (try #\(transfer.retryCount)): \(transfer.filename)")

        // Prepare metadata for transfer
        var transferMetadata: [String: Any] = [
            "transferType": "reliable_recording",
            "recordingId": transfer.recordingId.uuidString,
            "reliableTransferId": transfer.id.uuidString,
            "filename": transfer.filename,
            "duration": transfer.duration,
            "fileSize": transfer.fileSize,
            "createdAt": transfer.createdAt.timeIntervalSince1970,
            "retryCount": transfer.retryCount
        ]
        if let checksum = transfer.checksumMD5 {
            transferMetadata["checksumMD5"] = checksum
        }
        if let locationData = transfer.locationData {
            transferMetadata["locationData"] = locationData.toDictionary()
        }

        // Start file transfer
        let fileTransfer: WCSessionFileTransfer = session.transferFile(transfer.fileURL, metadata: transferMetadata)

        // Store transfer tracking info
        activeFileTransfers[transferKey] = fileTransfer
        transferStartTimes[transferKey] = Date()
        isTransferringAudio = true
        audioTransferProgress = 0.0

        // Observe real transfer progress for the UI
        transferProgressObservations[transferKey] = fileTransfer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.audioTransferProgress = fraction
            }
        }

        // Set transfer status to awaiting confirmation once started
        transfer.status = .awaitingConfirmation
        reliableTransfers[recordingId] = transfer
        saveReliableTransfers()
    }

    /// Start retry timer for reliable transfers
    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRetryTransfers()
            }
        }
    }

    /// Check for transfers that need retry
    private func checkAndRetryTransfers() {
        let transfersToRetry = reliableTransfers.values.filter { $0.shouldRetry }

        if !transfersToRetry.isEmpty {
            print("⌚ Checking \(transfersToRetry.count) transfers for retry...")

            for transfer in transfersToRetry {
                attemptReliableTransfer(transfer.recordingId)
            }
        }
    }

    /// Retry all eligible reliable transfers
    private func retryReliableTransfers() {
        let eligibleTransfers = reliableTransfers.values.filter { transfer in
            transfer.status == .pending || transfer.status == .failed
        }

        if !eligibleTransfers.isEmpty {
            print("⌚ Retrying \(eligibleTransfers.count) reliable transfers after connection restoration")

            for transfer in eligibleTransfers {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.5...2.0)) {
                    self.attemptReliableTransfer(transfer.recordingId)
                }
            }
        }
    }

    /// Confirm successful transfer and allow file deletion
    func confirmReliableTransfer(_ recordingId: UUID) {
        guard var transfer = reliableTransfers[recordingId] else {
            print("⚠️ Cannot confirm - reliable transfer not found: \(recordingId)")
            return
        }

        transfer.recordSuccess()
        print("✅ Reliable transfer confirmed: \(transfer.filename)")

        // NOW it's safe to delete the local file
        do {
            try FileManager.default.removeItem(at: transfer.fileURL)
            print("🗑️ Deleted local file after confirmation: \(transfer.filename)")
        } catch {
            print("⚠️ Failed to delete local file: \(error)")
        }

        reliableTransfers.removeValue(forKey: recordingId)
        saveReliableTransfers()
    }

    /// Mark transfer as failed
    func failReliableTransfer(_ recordingId: UUID, reason: String) {
        guard var transfer = reliableTransfers[recordingId] else {
            return
        }

        transfer.recordFailure(reason)
        reliableTransfers[recordingId] = transfer
        saveReliableTransfers()

        print("❌ Reliable transfer failed: \(transfer.filename) - \(reason) (retry \(transfer.retryCount)/5)")
    }

    /// Get pending reliable transfers count
    var pendingReliableTransfersCount: Int {
        return reliableTransfers.values.filter { $0.status != .confirmed }.count
    }

    // MARK: - Persistence

    private var reliableTransfersURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("reliable_transfers.json")
    }

    /// Save reliable transfers to disk
    private func saveReliableTransfers() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Array(reliableTransfers.values))
            try data.write(to: reliableTransfersURL)
        } catch {
            print("❌ Failed to save reliable transfers: \(error)")
        }
    }

    /// Load reliable transfers from disk
    private func loadReliableTransfers() {
        do {
            let data = try Data(contentsOf: reliableTransfersURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let transfers = try decoder.decode([ReliableTransfer].self, from: data)

            // Convert to dictionary and filter out old/invalid transfers
            reliableTransfers = Dictionary(uniqueKeysWithValues: transfers.compactMap { transfer in
                // Remove transfers older than 7 days or already confirmed
                let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                guard transfer.createdAt > cutoffDate && transfer.status != .confirmed else {
                    return nil
                }

                // Verify file still exists (stale entries are re-created from
                // storage metadata by WatchRecordingViewModel)
                guard FileManager.default.fileExists(atPath: transfer.fileURL.path) else {
                    print("⚠️ Removing transfer for missing file: \(transfer.filename)")
                    return nil
                }

                return (transfer.recordingId, transfer)
            })

            print("📂 Loaded \(reliableTransfers.count) reliable transfers from disk")

            if !reliableTransfers.isEmpty {
                saveReliableTransfers() // Clean up the saved file
            }

        } catch {
            print("ℹ️ No existing reliable transfers found (normal on first run)")
            reliableTransfers = [:]
        }
    }

    // MARK: - Message Processing

    private func processPhoneMessage(_ message: [String: Any]) {
        guard let messageTypeString = message["messageType"] as? String,
              let messageType = WatchRecordingMessage(rawValue: messageTypeString) else {
            print("⌚ Unknown or missing message type from phone: \(message["messageType"] ?? "nil")")
            return
        }

        switch messageType {
        case .phoneAppActivated:
            print("⌚ Phone app activated")
            isPhoneAppActive = true
            connectionState = .connected
            onPhoneAppActivated?()

        case .errorOccurred:
            if let errorMessage = WatchErrorMessage.fromDictionary(message) {
                print("⌚ Received error from phone: \(errorMessage.message)")
                onPhoneErrorReceived?(errorMessage)
            }

        case .connectionStatusUpdate:
            updateConnectionState()

        case .requestSync:
            print("⌚ Phone requested sync")
            // Pending recordings are re-enqueued by the view model on
            // phoneAppActivated / connection restore

        case .syncComplete:
            if let recordingIdString = message["recordingId"] as? String,
               let recordingId = UUID(uuidString: recordingIdString) {
                handleSyncCompleteConfirmation(recordingId)
            }

        case .syncFailed:
            if let recordingIdString = message["recordingId"] as? String,
               let recordingId = UUID(uuidString: recordingIdString),
               let reason = message["reason"] as? String {
                handleSyncFailedMessage(recordingId, reason: reason)
            }

        // Sent by watch, not received
        case .watchAppActivated:
            break
        }
    }

    private func handleSyncCompleteConfirmation(_ recordingId: UUID) {
        print("✅ iPhone confirmed sync complete for: \(recordingId)")

        // Confirm reliable transfer - this triggers file deletion
        confirmReliableTransfer(recordingId)

        // Forward to view model
        NotificationCenter.default.post(
            name: Notification.Name("WatchSyncComplete"),
            object: recordingId
        )
    }

    private func handleSyncFailedMessage(_ recordingId: UUID, reason: String) {
        print("❌ iPhone reported sync failed for: \(recordingId), reason: \(reason)")

        // Mark reliable transfer as failed
        failReliableTransfer(recordingId, reason: reason)

        // Forward to view model
        NotificationCenter.default.post(
            name: Notification.Name("WatchSyncFailed"),
            object: ["recordingId": recordingId, "reason": reason]
        )
    }

    // MARK: - Utility Methods

    private func getBatteryLevel() -> Float {
        #if canImport(WatchKit)
        return WKInterfaceDevice.current().batteryLevel
        #else
        return 1.0 // Fallback for non-watchOS platforms
        #endif
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                print("⌚ WCSession activation failed: \(error.localizedDescription)")
                self.connectionState = .error
                return
            }

            switch activationState {
            case .activated:
                print("⌚ Watch WCSession activated successfully")
                self.updateConnectionState()
            case .inactive:
                print("⌚ Watch WCSession inactive")
                self.connectionState = .disconnected
            case .notActivated:
                print("⌚ Watch WCSession not activated")
                self.connectionState = .error
            @unknown default:
                print("⌚ Watch WCSession unknown activation state")
                self.connectionState = .error
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            let wasReachable = self.connectionState == .connected
            print("⌚ Phone reachability changed: \(session.isReachable)")

            // Debounce connectivity changes to prevent rapid state churn
            self.connectivityDebounceTimer?.invalidate()
            self.connectivityDebounceTimer = Timer.scheduledTimer(withTimeInterval: self.connectivityDebounceDelay, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleDebouncedReachabilityChange(session: session, wasReachable: wasReachable)
                }
            }
        }
    }

    /// Handle debounced reachability changes
    private func handleDebouncedReachabilityChange(session: WCSession, wasReachable: Bool) {
        print("⌚ Processing debounced reachability change: \(session.isReachable)")
        updateConnectionState()

        if session.isReachable {
            if !wasReachable {
                // updateConnectionState already triggered handleConnectionRestored
                // for the transition; just request a sync
                requestSyncWithPhoneThrottled()
            }
        } else {
            if wasReachable {
                handleConnectionLost()
            }
        }
    }

    /// Request sync with phone using throttling
    private func requestSyncWithPhoneThrottled() {
        guard let session = session, session.isReachable else {
            return
        }

        let currentTime = Date()
        if let lastSync = lastSyncRequestTime,
           currentTime.timeIntervalSince(lastSync) < minSyncRequestInterval {
            print("⌚ Throttling sync request - too recent")
            return
        }

        lastSyncRequestTime = currentTime
        session.sendRecordingMessage(.requestSync)
        print("⌚ Sent throttled sync request")
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.processPhoneMessage(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.processPhoneMessage(message)

            // Send reply with current watch status
            let reply: [String: Any] = [
                "status": "received",
                "watchAppActive": true,
                "batteryLevel": self.getBatteryLevel(),
                "timestamp": Date().timeIntervalSince1970
            ]
            replyHandler(reply)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            print("⌚ Received application context from phone")
            self.processPhoneMessage(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            print("⌚ Received user info from phone")
            self.processPhoneMessage(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("⌚ Received file from phone: \(file.fileURL.lastPathComponent) - not supported, ignoring")
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            // Map the finished transfer back to its reliable-transfer record.
            // Fall back to the file metadata for transfers queued before a relaunch.
            let trackedKey = self.activeFileTransfers.first(where: { $0.value === fileTransfer })?.key
            let recordingIdString = trackedKey ?? (fileTransfer.file.metadata?["recordingId"] as? String)

            if let key = trackedKey {
                self.activeFileTransfers.removeValue(forKey: key)
                self.transferStartTimes.removeValue(forKey: key)
                self.transferProgressObservations.removeValue(forKey: key)?.invalidate()
            }
            self.isTransferringAudio = !self.activeFileTransfers.isEmpty

            if let error = error {
                print("⌚ File transfer failed: \(error.localizedDescription)")
                if let recordingIdString = recordingIdString,
                   let recordingId = UUID(uuidString: recordingIdString) {
                    // Mark failed so the retry timer picks it up with backoff
                    self.failReliableTransfer(recordingId, reason: error.localizedDescription)
                }
            } else {
                print("⌚ File transfer completed successfully - awaiting iPhone confirmation")
                self.audioTransferProgress = 1.0
            }
        }
    }
}

// MARK: - Reliable Transfer Types

/// Status of a reliable transfer
enum ReliableTransferStatus: String, Codable {
    case pending = "pending"
    case transferring = "transferring"
    case awaitingConfirmation = "awaiting_confirmation"
    case confirmed = "confirmed"
    case failed = "failed"
}

/// Reliable transfer record
struct ReliableTransfer: Codable, Identifiable {
    let id: UUID
    let recordingId: UUID
    let filename: String
    let fileURL: URL
    let duration: TimeInterval
    let fileSize: Int64
    let createdAt: Date
    let checksumMD5: String?
    let locationData: WatchLocationData?

    var status: ReliableTransferStatus
    var retryCount: Int
    var lastAttemptTime: Date
    var failureReason: String?

    init(from metadata: WatchRecordingMetadata, fileURL: URL) {
        self.id = UUID()
        self.recordingId = metadata.id
        self.filename = metadata.filename
        self.fileURL = fileURL
        self.duration = metadata.duration
        self.fileSize = metadata.fileSize
        self.createdAt = metadata.createdAt
        self.locationData = metadata.locationData

        // Calculate checksum from file data
        self.checksumMD5 = Self.calculateMD5(for: fileURL)

        self.status = .pending
        self.retryCount = 0
        self.lastAttemptTime = Date()
        self.failureReason = nil
    }

    var shouldRetry: Bool {
        guard retryCount < 5 else { return false }

        let timeSinceLastAttempt = Date().timeIntervalSince(lastAttemptTime)

        switch status {
        case .pending, .failed:
            let minDelay: TimeInterval = {
                switch retryCount {
                case 0: return 0
                case 1: return 10  // 10 seconds
                case 2: return 60  // 1 minute
                case 3: return 300 // 5 minutes
                default: return 600 // 10 minutes
                }
            }()
            return timeSinceLastAttempt >= minDelay

        case .awaitingConfirmation:
            // The transfer finished but no confirmation arrived - it may have
            // been lost. Retry after a long delay; the iPhone dedupes by
            // recordingId and re-acks duplicates instead of re-importing.
            return timeSinceLastAttempt >= 600

        case .transferring, .confirmed:
            return false
        }
    }

    mutating func recordAttempt() {
        retryCount += 1
        lastAttemptTime = Date()
        status = .transferring
    }

    mutating func recordSuccess() {
        status = .confirmed
    }

    mutating func recordFailure(_ reason: String) {
        status = .failed
        failureReason = reason
    }

    /// Calculate MD5 checksum for file
    private static func calculateMD5(for url: URL) -> String? {
        do {
            let data = try Data(contentsOf: url)
            let digest = Insecure.MD5.hash(data: data)
            return digest.map { String(format: "%02hhx", $0) }.joined()
        } catch {
            print("⚠️ Failed to calculate MD5 checksum: \(error)")
            return nil
        }
    }
}
