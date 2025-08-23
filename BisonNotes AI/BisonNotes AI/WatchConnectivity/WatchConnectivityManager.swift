//
//  WatchConnectivityManager.swift
//  BisonNotes AI (iOS)
//
//  Created by Claude on 8/17/25.
//

import Foundation
@preconcurrency import WatchConnectivity
import Combine
import UIKit

/// Manages WatchConnectivity session and communication with Apple Watch
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isWatchAppInstalled: Bool = false
    @Published var lastWatchMessage: String = ""
    @Published var watchRecordingState: WatchRecordingState = .idle
    @Published var watchBatteryLevel: Float?
    @Published var isReceivingAudioChunks: Bool = false
    
    // State synchronization
    @Published var phoneRecordingState: WatchRecordingState = .idle
    @Published var lastStateSyncTime: Date = Date()
    @Published var stateConflictDetected: Bool = false
    
    // MARK: - Private Properties
    private var session: WCSession? {
        didSet {
            if let session = session {
                session.delegate = self
            }
        }
    }
    private var audioChunkManager = WatchAudioChunkManager()
    private var cancellables = Set<AnyCancellable>()
    
    // Sync operation tracking
    private var pendingSyncOperations: [UUID: WatchSyncRequest] = [:]
    private var syncTimeouts: [UUID: Timer] = [:]
    
    // State synchronization
    private var stateSyncTimer: Timer?
    private var lastWatchStateChange: Date = Date()
    private var lastPhoneStateChange: Date = Date()
    private var syncInterval: TimeInterval = 2.0 // Sync every 2 seconds
    private var conflictResolutionStrategy: StateConflictResolution = .phoneWins
    
    // MARK: - File sync callbacks (current)
    var onWatchSyncRecordingReceived: ((Data, WatchSyncRequest) -> Void)?
    var onWatchRecordingSyncCompleted: ((UUID, Bool) -> Void)?
    
    // Legacy callbacks removed - watch operates independently
    // var onWatchRecordingStartRequested, onWatchRecordingStopRequested, etc.
    // var onWatchAudioReceived - replaced by file transfer
    
    // State synchronization callbacks
    var onStateConflictDetected: ((WatchRecordingState, WatchRecordingState) -> Void)? // phone state, watch state
    var onStateSyncCompleted: (() -> Void)?
    var onConnectionRestored: (() -> Void)?
    
    // MARK: - Singleton
    static let shared = WatchConnectivityManager()
    
    override init() {
        super.init()
        setupWatchConnectivity()
        setupNotificationObservers()
        // Removed automatic state synchronization - only sync on-demand for recordings
        // startStateSynchronization()
    }
    
    deinit {
        // Clean up session safely
        if let session = session {
            session.delegate = nil
        }
        self.session = nil
        stateSyncTimer?.invalidate()
        
        // Clean up sync operations
        for (_, timeout) in syncTimeouts {
            timeout.invalidate()
        }
        syncTimeouts.removeAll()
        pendingSyncOperations.removeAll()
    }
    
    // MARK: - Setup Methods
    
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            print("📱 WatchConnectivity not supported on this device")
            connectionState = .error
            return
        }
        
        // Initialize session safely
        let wcSession = WCSession.default
        self.session = wcSession
        wcSession.activate()
        
        print("📱 iPhone WatchConnectivity session setup initiated - activating...")
    }
    
    // MARK: - New Sync Protocol Methods
    
    /// Check if iPhone app is ready to receive recordings
    private func checkAppReadiness(request: [String: Any]) -> WatchAppReadinessResponse {
        // Check if app is in foreground
        let appState = UIApplication.shared.applicationState
        let isInForeground = appState == .active
        
        // Check available storage (simplified)
        let availableStorage: Int64 = 100 * 1024 * 1024 // Assume 100MB available
        
        // Check Core Data availability
        let coreDataReady = true // Assume Core Data is ready
        
        var ready = true
        var reason = "ready"
        
        if !isInForeground {
            reason = "backgrounded"
            // Still ready, but backgrounded
        }
        
        // Check if we have enough storage for the file
        if let requestedSize = request["fileSize"] as? Int64,
           requestedSize > availableStorage {
            ready = false
            reason = "insufficient_storage"
        }
        
        return WatchAppReadinessResponse(
            ready: ready,
            reason: reason,
            storageAvailable: availableStorage,
            coreDataReady: coreDataReady
        )
    }
    
    /// Handle sync request from watch
    private func handleSyncRequest(_ syncRequest: WatchSyncRequest) -> Bool {
        print("📱 Received sync request for: \(syncRequest.filename)")
        
        // Check if we can accept the sync
        let appState = UIApplication.shared.applicationState
        let canAccept = appState == .active || appState == .background
        
        if canAccept {
            // Store pending sync operation
            pendingSyncOperations[syncRequest.recordingId] = syncRequest
            
            // Set timeout for sync completion (dynamic based on file size and app state)
            let timeoutDuration = calculateSyncTimeout(for: syncRequest)
            let timeout = Timer.scheduledTimer(withTimeInterval: timeoutDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    print("📱 Sync timeout after \(timeoutDuration)s for: \(syncRequest.filename)")
                    self?.handleSyncTimeout(syncRequest.recordingId)
                }
            }
            syncTimeouts[syncRequest.recordingId] = timeout
            
            print("📱 Sync request accepted for: \(syncRequest.filename)")
            return true
        } else {
            print("📱 Sync request rejected - app not ready")
            return false
        }
    }
    
    /// Handle completed file transfer from watch
    private func handleWatchRecordingReceived(fileURL: URL, metadata: [String: Any]) {
        // Request background task to ensure processing completes even if app is backgrounded
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatchFileProcessing") {
            print("⚠️ Background task expired during watch file processing")
        }
        
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
        
        guard let recordingIdString = metadata["recordingId"] as? String,
              let recordingId = UUID(uuidString: recordingIdString) else {
            print("❌ Received file but no recording ID in metadata")
            return
        }
        
        // Try to get pending sync request, or reconstruct from metadata if missing
        let syncRequest: WatchSyncRequest
        if let pendingRequest = pendingSyncOperations[recordingId] {
            syncRequest = pendingRequest
        } else {
            print("⚠️ No pending sync request found, reconstructing from metadata")
            
            // Reconstruct sync request from metadata
            guard let filename = metadata["filename"] as? String,
                  let duration = metadata["duration"] as? TimeInterval,
                  let fileSize = metadata["fileSize"] as? Int64,
                  let createdAtTimestamp = metadata["createdAt"] as? TimeInterval else {
                print("❌ Insufficient metadata to reconstruct sync request")
                return
            }
            
            syncRequest = WatchSyncRequest(
                recordingId: recordingId,
                filename: filename,
                duration: duration,
                fileSize: fileSize,
                createdAt: Date(timeIntervalSince1970: createdAtTimestamp),
                checksumMD5: ""
            )
        }
        
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let fileSizeMB = Double(fileSize) / (1024 * 1024)
        print("📱 Received recording file: \(fileURL.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB)")
        
        do {
            // Read the audio data
            let audioData = try Data(contentsOf: fileURL)
            
            // Verify checksum if provided
            if !syncRequest.checksumMD5.isEmpty {
                let actualChecksum = audioData.md5
                if actualChecksum != syncRequest.checksumMD5 {
                    print("⚠️ Checksum mismatch for \(syncRequest.filename)")
                    handleSyncFailure(recordingId, reason: "checksum_mismatch")
                    return
                }
            }
            
            // Log reliable transfer info if available
            if let transferType = metadata["transferType"] as? String,
               transferType == "reliable_recording",
               let retryCount = metadata["retryCount"] as? Int {
                print("🔄 Processing reliable transfer (retry #\(retryCount)): \(syncRequest.filename)")
            }
            
            // Create Core Data entry via callback
            print("📱 About to call onWatchSyncRecordingReceived callback for: \(syncRequest.recordingId)")
            if onWatchSyncRecordingReceived != nil {
                print("📱 Callback exists, calling it now")
                onWatchSyncRecordingReceived?(audioData, syncRequest)
            } else {
                print("❌ onWatchSyncRecordingReceived callback is nil! File will not be processed.")
                handleSyncFailure(recordingId, reason: "callback_not_set")
            }
            
            // Cleanup and confirmation will happen in confirmSyncComplete
            
        } catch {
            print("❌ Failed to read received file: \(error)")
            handleSyncFailure(recordingId, reason: "file_read_error")
        }
    }
    
    /// Confirm sync completion to watch with enhanced reliability
    func confirmSyncComplete(recordingId: UUID, success: Bool, coreDataId: String? = nil) {
        if success {
            print("✅ Sync completed successfully for: \(recordingId)")
            
            // Send enhanced confirmation to watch
            var confirmationInfo: [String: Any] = [
                "recordingId": recordingId.uuidString,
                "confirmed": true,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            if let coreDataId = coreDataId {
                confirmationInfo["coreDataId"] = coreDataId
                print("📊 Reliable transfer confirmed in Core Data: \(coreDataId)")
            }
            
            // Send confirmation with retry logic for connection issues
            sendConfirmationWithRetry(confirmationInfo: confirmationInfo, recordingId: recordingId)
            
            // Cleanup
            cleanupSyncOperation(recordingId)
            
        } else {
            handleSyncFailure(recordingId, reason: "core_data_error")
        }
    }
    
    /// Send confirmation with retry logic for connection issues
    private func sendConfirmationWithRetry(confirmationInfo: [String: Any], recordingId: UUID, attempt: Int = 1) {
        let maxAttempts = 3
        
        print("📱 Sending confirmation attempt \(attempt)/\(maxAttempts) for: \(recordingId)")
        
        // Try to send the confirmation
        sendRecordingCommand(.syncComplete, additionalInfo: confirmationInfo)
        
        // If this isn't the last attempt, schedule a retry
        if attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // Only retry if connection is still unstable
                if let session = self.session, session.isReachable {
                    print("📱 Connection restored, skipping retry for: \(recordingId)")
                    return
                }
                
                print("📱 Connection still unstable, retrying confirmation for: \(recordingId)")
                self.sendConfirmationWithRetry(confirmationInfo: confirmationInfo, recordingId: recordingId, attempt: attempt + 1)
            }
        } else {
            print("⚠️ Max confirmation attempts reached for: \(recordingId)")
        }
    }
    
    private func handleSyncTimeout(_ recordingId: UUID) {
        print("⏰ Sync timeout for: \(recordingId)")
        handleSyncFailure(recordingId, reason: "timeout")
    }
    
    private func handleSyncFailure(_ recordingId: UUID, reason: String) {
        print("❌ Sync failed for: \(recordingId), reason: \(reason)")
        
        // Send failure message to watch
        sendRecordingCommand(.syncFailed, additionalInfo: [
            "recordingId": recordingId.uuidString,
            "reason": reason,
            "timestamp": Date().timeIntervalSince1970
        ])
        
        // Cleanup
        cleanupSyncOperation(recordingId)
    }
    
    private func cleanupSyncOperation(_ recordingId: UUID) {
        pendingSyncOperations.removeValue(forKey: recordingId)
        syncTimeouts[recordingId]?.invalidate()
        syncTimeouts.removeValue(forKey: recordingId)
    }
    
    /// Calculate appropriate sync timeout based on file size and app state
    private func calculateSyncTimeout(for syncRequest: WatchSyncRequest) -> TimeInterval {
        // Base timeout calculation: 60s base + time based on file size
        let fileSizeMB = Double(syncRequest.fileSize) / (1024 * 1024)
        let sizeBasedTimeout = 60.0 + (fileSizeMB * 10.0) // 10s per MB
        
        // Check if app is backgrounded
        let appState = UIApplication.shared.applicationState
        let isBackgrounded = appState != .active
        
        if isBackgrounded {
            // Much longer timeout when backgrounded - iOS gives limited time
            let backgroundTimeout = max(180.0, min(600.0, sizeBasedTimeout * 2.0)) // 3-10 minutes
            print("📱 App backgrounded, using extended sync timeout: \(backgroundTimeout)s")
            return backgroundTimeout
        } else {
            // Normal timeout when active
            let activeTimeout = max(120.0, min(300.0, sizeBasedTimeout)) // 2-5 minutes
            print("📱 App active, using normal sync timeout: \(activeTimeout)s")
            return activeTimeout
        }
    }
    
    private func setupNotificationObservers() {
        // Listen for app lifecycle events
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
                    self?.handleAppWillResignActive()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Interface
    
    /// Send recording command to watch
    func sendRecordingCommand(_ message: WatchRecordingMessage, additionalInfo: [String: Any]? = nil) {
        guard let session = session, session.activationState == .activated, session.isReachable else {
            print("⌚ Cannot send recording command - watch not reachable or session not activated")
            connectionState = .disconnected
            return
        }
        
        session.sendRecordingMessage(message, userInfo: additionalInfo)
        print("⌚ Sent recording command to watch: \(message.rawValue)")
    }
    
    /// Send current recording status to watch
    func sendRecordingStatusToWatch(_ state: WatchRecordingState, recordingTime: TimeInterval, error: String? = nil) {
        let statusUpdate = WatchRecordingStatusUpdate(
            state: state,
            recordingTime: recordingTime,
            errorMessage: error
        )
        
        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot send status update - session not available")
            return
        }
        session.sendStatusUpdate(statusUpdate)
        print("⌚ Sent status update to watch: \(state.rawValue)")
    }
    
    /// Request sync with watch app
    func requestSyncWithWatch() {
        sendRecordingCommand(.requestSync)
    }
    
    /// Handle phone app activation when watch starts recording
    func activatePhoneAppForRecording() {
        // Send confirmation that phone app is now active
        sendRecordingCommand(.phoneAppActivated)
        
        // Legacy recording coordination removed - watch operates independently
        
        print("⌚ Phone app activated for watch recording")
    }
    
    // MARK: - State Synchronization
    
    /// Update the phone recording state and sync with watch
    func updatePhoneRecordingState(_ newState: WatchRecordingState) {
        guard phoneRecordingState != newState else { return }
        
        let previousState = phoneRecordingState
        phoneRecordingState = newState
        lastPhoneStateChange = Date()
        lastStateSyncTime = Date()
        
        print("📱 Phone state changed: \(previousState.rawValue) → \(newState.rawValue)")
        
        // Send state update to watch immediately
        sendPhoneStateToWatch(newState)
        
        // Check for conflicts
        if watchRecordingState != newState && connectionState.isConnected {
            detectAndResolveStateConflict()
        }
    }
    
    /// Send current phone recording state to watch
    private func sendPhoneStateToWatch(_ state: WatchRecordingState) {
        guard let session = session, session.activationState == .activated else {
            print("📱 Cannot send state - session not available")
            return
        }
        
        let stateMessage: [String: Any] = [
            "messageType": "phoneStateUpdate",
            "recordingState": state.rawValue,
            "timestamp": lastPhoneStateChange.timeIntervalSince1970
        ]
        
        if session.isReachable {
            session.sendMessage(stateMessage, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.handleStateUpdateReply(reply)
                }
            }) { [weak self] error in
                Task { @MainActor in
                    self?.handleStateUpdateError(error)
                }
            }
        } else {
            // Store state for later sync when connection is restored
            print("📱 Watch not reachable, will sync state when connected")
        }
    }
    
    /// Handle reply from watch after state update
    private func handleStateUpdateReply(_ reply: [String: Any]) {
        if let watchStateString = reply["watchRecordingState"] as? String,
           let watchState = WatchRecordingState(rawValue: watchStateString),
           let timestamp = reply["timestamp"] as? TimeInterval {
            
            lastWatchStateChange = Date(timeIntervalSince1970: timestamp)
            
            if watchRecordingState != watchState {
                watchRecordingState = watchState
                print("📱 Received watch state update: \(watchState.rawValue)")
                
                // Check for conflicts
                if phoneRecordingState != watchState {
                    detectAndResolveStateConflict()
                }
            }
        }
    }
    
    /// Handle error when sending state update
    private func handleStateUpdateError(_ error: Error) {
        print("❌ Failed to send state update: \(error.localizedDescription)")
        // Will retry on next sync cycle
    }
    
    /// Start periodic state synchronization
    private func startStateSynchronization() {
        stateSyncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performPeriodicStateSync()
            }
        }
        print("📱 Started state synchronization (interval: \(syncInterval)s)")
    }
    
    /// Perform periodic state synchronization
    private func performPeriodicStateSync() {
        guard connectionState.isConnected else { return }
        
        // Send current state as heartbeat
        sendPhoneStateToWatch(phoneRecordingState)
        
        // Check if we haven't heard from watch in a while
        let watchStateAge = Date().timeIntervalSince(lastWatchStateChange)
        if watchStateAge > (syncInterval * 3) {
            print("⚠️ Watch state seems stale, requesting sync")
            requestWatchStateUpdate()
        }
    }
    
    /// Request current state from watch
    private func requestWatchStateUpdate() {
        guard let session = session, session.activationState == .activated, session.isReachable else {
            return
        }
        
        let requestMessage: [String: Any] = [
            "messageType": "requestStateSync",
            "phoneState": phoneRecordingState.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session.sendMessage(requestMessage, replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.handleStateUpdateReply(reply)
            }
        }) { error in
            print("❌ Failed to request watch state: \(error.localizedDescription)")
        }
    }
    
    /// Detect and resolve state conflicts between phone and watch
    private func detectAndResolveStateConflict() {
        guard phoneRecordingState != watchRecordingState else {
            stateConflictDetected = false
            return
        }
        
        print("⚠️ State conflict detected - Phone: \(phoneRecordingState.rawValue), Watch: \(watchRecordingState.rawValue)")
        stateConflictDetected = true
        
        onStateConflictDetected?(phoneRecordingState, watchRecordingState)
        
        // Apply conflict resolution strategy
        resolveStateConflict()
    }
    
    /// Resolve state conflict based on strategy
    private func resolveStateConflict() {
        let resolution = determineConflictResolution()
        
        switch resolution {
        case .phoneWins:
            print("🔄 Resolving conflict: Phone wins, sending phone state to watch")
            sendPhoneStateToWatch(phoneRecordingState)
            
        case .watchWins:
            print("🔄 Resolving conflict: Watch wins, updating phone state to \(watchRecordingState.rawValue)")
            phoneRecordingState = watchRecordingState
            
        case .mostRecentWins:
            if lastPhoneStateChange > lastWatchStateChange {
                print("🔄 Resolving conflict: Phone state is more recent")
                sendPhoneStateToWatch(phoneRecordingState)
            } else {
                print("🔄 Resolving conflict: Watch state is more recent")
                phoneRecordingState = watchRecordingState
            }
            
        case .smartResolution:
            performSmartConflictResolution()
        }
        
        stateConflictDetected = false
        onStateSyncCompleted?()
    }
    
    /// Determine appropriate conflict resolution strategy
    private func determineConflictResolution() -> StateConflictResolution {
        // Use smart resolution for recording states
        if phoneRecordingState.isRecordingSession || watchRecordingState.isRecordingSession {
            return .smartResolution
        }
        
        // Default to configured strategy
        return conflictResolutionStrategy
    }
    
    /// Perform intelligent conflict resolution based on state semantics
    private func performSmartConflictResolution() {
        // Priority rules:
        // 1. Any device actively recording wins over idle/paused
        // 2. Error states should be respected
        // 3. Processing states should not be interrupted
        
        if phoneRecordingState == .recording && watchRecordingState != .recording {
            print("🧠 Smart resolution: Phone is actively recording, phone wins")
            sendPhoneStateToWatch(phoneRecordingState)
        } else if watchRecordingState == .recording && phoneRecordingState != .recording {
            print("🧠 Smart resolution: Watch is actively recording, watch wins")
            phoneRecordingState = watchRecordingState
        } else if phoneRecordingState == .error || watchRecordingState == .error {
            print("🧠 Smart resolution: Error state detected, syncing to error")
            let errorState: WatchRecordingState = .error
            if phoneRecordingState != errorState {
                phoneRecordingState = errorState
            }
            sendPhoneStateToWatch(errorState)
        } else if phoneRecordingState == .processing || watchRecordingState == .processing {
            print("🧠 Smart resolution: Processing state detected, maintaining processing")
            let processingState: WatchRecordingState = .processing
            if phoneRecordingState != processingState {
                phoneRecordingState = processingState
            }
            sendPhoneStateToWatch(processingState)
        } else {
            // Fall back to most recent change
            if lastPhoneStateChange > lastWatchStateChange {
                sendPhoneStateToWatch(phoneRecordingState)
            } else {
                phoneRecordingState = watchRecordingState
            }
        }
    }
    
    // MARK: - App Lifecycle Handlers
    
    private func handleAppBecameActive() {
        // Notify watch that phone app is active
        sendRecordingCommand(.phoneAppActivated)
        
        // Request status sync
        requestSyncWithWatch()
        
        // Update connection state
        updateConnectionState()
    }
    
    private func handleAppWillResignActive() {
        // Let watch know phone app is going inactive
        // Don't stop recording, just update status
        updateConnectionState()
    }
    
    private func updateConnectionState() {
        guard let session = session else {
            connectionState = .error
            return
        }
        
        let previousState = connectionState
        
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
        
        // Handle connection restoration
        if previousState != .connected && connectionState == .connected {
            handleConnectionRestored()
        }
    }
    
    /// Handle connection restoration - trigger state recovery
    private func handleConnectionRestored() {
        print("📱 Connection restored")
        
        onConnectionRestored?()
        
        // Only sync state if phone is actually recording
        if phoneRecordingState != .idle {
            print("📱 Phone is recording, syncing state with watch")
            requestWatchStateUpdate()
            sendPhoneStateToWatch(phoneRecordingState)
        }
    }
    
    // MARK: - Audio Chunk Processing
    
    private func handleAudioChunkReceived(_ chunk: WatchAudioChunk) {
        // Validate chunk data
        guard validateAudioChunk(chunk) else {
            print("❌ Invalid audio chunk received: \(chunk.sequenceNumber)")
            sendChunkValidationError(chunk: chunk, error: "Invalid chunk data")
            return
        }
        
        // Start new recording session if this is the first chunk or new session
        if audioChunkManager.currentRecordingSession != chunk.recordingSessionId {
            if audioChunkManager.currentRecordingSession != nil {
                print("⚠️ New recording session started, resetting chunk manager")
                audioChunkManager.reset()
            }
            audioChunkManager.currentRecordingSession = chunk.recordingSessionId
            print("📱 Started receiving chunks for recording session: \(chunk.recordingSessionId)")
        }
        
        // Check for duplicate chunks
        if audioChunkManager.hasChunk(sequenceNumber: chunk.sequenceNumber) {
            print("⚠️ Duplicate chunk received: \(chunk.sequenceNumber) - ignoring")
            sendChunkAcknowledgment(chunk: chunk) // Still acknowledge to prevent retries
            return
        }
        
        // Check for reasonable chunk size (1 second of 16kHz mono 16-bit audio ≈ 32KB)
        let expectedSize = Int(WatchAudioFormat.expectedChunkDataSize(durationSeconds: chunk.duration))
        let tolerance = expectedSize / 2 // Allow 50% variance
        
        if chunk.audioData.count < (expectedSize - tolerance) || chunk.audioData.count > (expectedSize + tolerance) {
            print("⚠️ Chunk size unusual: expected ~\(expectedSize), got \(chunk.audioData.count) bytes")
        }
        
        audioChunkManager.addReceivedChunk(chunk)
        isReceivingAudioChunks = true
        
        print("⌚ Received audio chunk \(chunk.sequenceNumber) of session \(chunk.recordingSessionId) (\(chunk.audioData.count) bytes)")
        
        // Send acknowledgment to watch
        sendChunkAcknowledgment(chunk: chunk)
        
        // If this is the last chunk, process the complete audio
        if chunk.isLastChunk {
            processCompleteWatchAudio()
        }
    }
    
    private func processCompleteWatchAudio() {
        // Check for missing chunks before processing
        let missingChunks = audioChunkManager.getMissingChunks()
        if !missingChunks.isEmpty {
            print("⚠️ Missing \(missingChunks.count) chunks, requesting them...")
            requestMissingChunks()
            
            // Wait a bit and try again (for now just log, could implement timeout logic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let stillMissing = self.audioChunkManager.getMissingChunks()
                if stillMissing.isEmpty {
                    self.processCompleteWatchAudio() // Retry
                } else {
                    print("❌ Still missing chunks after retry, proceeding with incomplete audio")
                    self.forceProcessIncompleteAudio()
                }
            }
            return
        }
        
        guard let combinedAudio = audioChunkManager.combineAudioChunks(),
              let sessionId = audioChunkManager.currentRecordingSession else {
            print("❌ Failed to combine watch audio chunks")
            return
        }
        
        print("✅ Successfully combined \(audioChunkManager.chunksReceived) audio chunks (\(combinedAudio.count) bytes)")
        
        // Legacy audio streaming removed - now using file transfer on completion
        
        // Reset for next recording
        audioChunkManager.reset()
        isReceivingAudioChunks = false
        
        // Confirm receipt to watch
        sendRecordingCommand(.audioTransferComplete, additionalInfo: [
            "sessionId": sessionId.uuidString,
            "totalBytes": combinedAudio.count
        ])
    }
    
    private func forceProcessIncompleteAudio() {
        guard let sessionId = audioChunkManager.currentRecordingSession else {
            print("❌ No session ID for incomplete audio processing")
            return
        }
        
        let missingCount = audioChunkManager.getMissingChunks().count
        
        // Try to combine what we have (now includes gap filling)
        if let audioWithGaps = audioChunkManager.combineAudioChunks() {
            print("✅ Processing audio with \(missingCount) gaps filled: \(audioChunkManager.chunksReceived) chunks (\(audioWithGaps.count) bytes)")
            // Legacy audio streaming removed - now using file transfer on completion
        } else {
            print("❌ Failed to process audio even with gap filling")
        }
        
        // Reset for next recording
        audioChunkManager.reset()
        isReceivingAudioChunks = false
        
        // Inform watch of completion (even if partial)
        sendRecordingCommand(.audioTransferComplete, additionalInfo: [
            "sessionId": sessionId.uuidString,
            "status": missingCount > 0 ? "partial" : "complete",
            "missingChunks": missingCount
        ])
    }
    
    // MARK: - Chunk Validation and Recovery
    
    private func validateAudioChunk(_ chunk: WatchAudioChunk) -> Bool {
        // Basic validation checks
        guard !chunk.audioData.isEmpty else {
            print("❌ Chunk validation failed: empty audio data")
            return false
        }
        
        guard chunk.duration > 0 && chunk.duration <= 10.0 else {
            print("❌ Chunk validation failed: invalid duration \(chunk.duration)")
            return false
        }
        
        guard chunk.sampleRate == WatchAudioFormat.sampleRate else {
            print("❌ Chunk validation failed: invalid sample rate \(chunk.sampleRate)")
            return false
        }
        
        guard chunk.channels == WatchAudioFormat.channels else {
            print("❌ Chunk validation failed: invalid channels \(chunk.channels)")
            return false
        }
        
        guard chunk.sequenceNumber >= 0 else {
            print("❌ Chunk validation failed: invalid sequence number \(chunk.sequenceNumber)")
            return false
        }
        
        // Check for reasonable audio data size (not too small, not too large)
        let minSize = 1000 // At least 1KB
        let maxSize = 100 * 1024 // At most 100KB
        
        guard chunk.audioData.count >= minSize && chunk.audioData.count <= maxSize else {
            print("❌ Chunk validation failed: unreasonable size \(chunk.audioData.count) bytes")
            return false
        }
        
        return true
    }
    
    private func sendChunkAcknowledgment(chunk: WatchAudioChunk) {
        guard let session = session, session.activationState == .activated else { return }
        
        let ackMessage: [String: Any] = [
            "messageType": "chunkAcknowledgment",
            "chunkId": chunk.chunkId.uuidString,
            "sequenceNumber": chunk.sequenceNumber,
            "sessionId": chunk.recordingSessionId.uuidString,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session.sendMessage(ackMessage, replyHandler: nil) { error in
            print("❌ Failed to send chunk acknowledgment: \(error.localizedDescription)")
        }
    }
    
    private func sendChunkValidationError(chunk: WatchAudioChunk, error: String) {
        guard let session = session, session.activationState == .activated else { return }
        
        let errorMessage: [String: Any] = [
            "messageType": "chunkValidationError",
            "chunkId": chunk.chunkId.uuidString,
            "sequenceNumber": chunk.sequenceNumber,
            "sessionId": chunk.recordingSessionId.uuidString,
            "error": error,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session.sendMessage(errorMessage, replyHandler: nil) { sendError in
            print("❌ Failed to send chunk validation error: \(sendError.localizedDescription)")
        }
    }
    
    private func requestMissingChunks() {
        guard let sessionId = audioChunkManager.currentRecordingSession else { return }
        
        let missingChunks = audioChunkManager.getMissingChunks()
        guard !missingChunks.isEmpty else { return }
        
        print("⚠️ Requesting \(missingChunks.count) missing chunks: \(missingChunks)")
        
        let requestMessage: [String: Any] = [
            "messageType": "requestMissingChunks",
            "sessionId": sessionId.uuidString,
            "missingSequenceNumbers": missingChunks,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session?.sendMessage(requestMessage, replyHandler: nil) { error in
            print("❌ Failed to send missing chunks request: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Error Handling
    
    private func handleWatchError(_ error: WatchErrorMessage) {
        print("⌚ Received error from watch: \(error.message)")
        
        // Update local state
        if error.errorType == .connectionLost {
            connectionState = .disconnected
        }
        
        // Legacy error forwarding removed - errors handled in sync protocol
    }
    
    // MARK: - Message Processing
    
    private func processWatchMessage(_ message: [String: Any]) {
        guard let messageTypeString = message["messageType"] as? String else {
            print("⌚ No message type in received message")
            return
        }
        
        // Handle state synchronization messages first
        if messageTypeString == "watchStateUpdate" {
            handleWatchStateUpdate(message)
            return
        } else if messageTypeString == "requestStateSync" {
            handleStateSync(message)
            return
        } else if messageTypeString == "watchAppTerminating" {
            handleWatchAppTermination(message)
            return
        }
        
        // Handle standard WatchRecordingMessage types
        guard let messageType = WatchRecordingMessage(rawValue: messageTypeString) else {
            print("⌚ Unknown message type received from watch: \(messageTypeString)")
            return
        }
        
        lastWatchMessage = messageType.rawValue
        
        switch messageType {
        case .startRecording, .stopRecording, .pauseRecording, .resumeRecording:
            print("⚠️ Ignoring legacy recording control message: \(messageType.rawValue) - watch operates independently")
            
        case .recordingStatusUpdate:
            if let statusUpdate = WatchRecordingStatusUpdate.fromDictionary(message) {
                watchRecordingState = statusUpdate.state
                watchBatteryLevel = statusUpdate.batteryLevel
                print("⌚ Watch status update: \(statusUpdate.state.rawValue)")
            }
            
        case .errorOccurred:
            if let errorMessage = WatchErrorMessage.fromDictionary(message) {
                handleWatchError(errorMessage)
            }
            
        case .audioChunkTransfer:
            if let audioChunk = WatchAudioChunk.fromDictionary(message) {
                handleAudioChunkReceived(audioChunk)
            }
            
        case .watchAppActivated:
            print("⌚ Watch app activated")
            connectionState = .connected
            
        case .requestSync:
            print("⌚ Watch requested sync")
            // Send current phone status to watch
            // This will be handled by AudioRecorderViewModel
            
        case .audioTransferComplete:
            print("⌚ Watch confirmed audio transfer complete")
            isReceivingAudioChunks = false
            
        case .chunkAcknowledgment:
            // This message is sent by phone to watch, not received by phone
            break
            
        case .connectionStatusUpdate:
            updateConnectionState()
            
        case .phoneAppActivated:
            // This message is sent by watch, we don't process it
            break
            
        case .requestPhoneAppActivation:
            // Watch is requesting phone app activation
            print("📱 Watch requested iPhone app activation")
            handleWatchActivationRequest(message)
        
        // MARK: - New Sync Protocol Messages
        case .checkAppReadiness:
            print("📱 Watch checking iPhone app readiness")
            let readinessResponse = checkAppReadiness(request: message)
            session?.sendAppReadinessResponse(readinessResponse)
            
        case .syncRequest:
            if let syncRequestData = WatchSyncRequest.fromDictionary(message) {
                let accepted = handleSyncRequest(syncRequestData)
                let response = WatchSyncResponse(
                    recordingId: syncRequestData.recordingId,
                    accepted: accepted,
                    reason: accepted ? nil : "app_not_ready"
                )
                session?.sendSyncResponse(response)
            }
            
        case .syncComplete:
            if let recordingIdString = message["recordingId"] as? String,
               let recordingId = UUID(uuidString: recordingIdString) {
                print("📱 Watch confirmed sync complete for: \(recordingId)")
                cleanupSyncOperation(recordingId)
            }
            
        // These messages are sent by iPhone to watch, not received
        case .appReadinessResponse, .syncAccepted, .syncRejected, .fileTransferStart, .fileReceived, .metadataTransfer, .coreDataCreated, .syncFailed:
            break
        }
    }
    
    /// Handle watch activation request
    private func handleWatchActivationRequest(_ message: [String: Any]) {
        print("📱 Processing watch activation request")
        
        // Ensure app is in foreground and ready
        DispatchQueue.main.async {
            // Activate phone app for recording
            self.activatePhoneAppForRecording()
            
            // Send confirmation back to watch
            self.sendRecordingCommand(.phoneAppActivated, additionalInfo: [
                "activatedAt": Date().timeIntervalSince1970,
                "appState": "active"
            ])
            
            print("📱 Sent activation confirmation to watch")
        }
    }
    
    /// Handle watch state update message
    private func handleWatchStateUpdate(_ message: [String: Any]) {
        guard let watchStateString = message["recordingState"] as? String,
              let watchState = WatchRecordingState(rawValue: watchStateString),
              let timestamp = message["timestamp"] as? TimeInterval else {
            print("📱 Invalid watch state update message")
            return
        }
        
        lastWatchStateChange = Date(timeIntervalSince1970: timestamp)
        
        if watchRecordingState != watchState {
            let previousWatchState = watchRecordingState
            watchRecordingState = watchState
            print("📱 Watch state updated: \(previousWatchState.rawValue) → \(watchState.rawValue)")
            
            // Check for conflicts
            if phoneRecordingState != watchState {
                detectAndResolveStateConflict()
            }
        }
    }
    
    /// Handle state sync request from watch
    private func handleStateSync(_ message: [String: Any]) {
        print("📱 Watch requested state sync")
        
        // Send current phone state immediately
        sendPhoneStateToWatch(phoneRecordingState)
        
        // If watch state is included, update it
        if let watchStateString = message["watchState"] as? String,
           let watchState = WatchRecordingState(rawValue: watchStateString),
           let timestamp = message["timestamp"] as? TimeInterval {
            
            lastWatchStateChange = Date(timeIntervalSince1970: timestamp)
            
            if watchRecordingState != watchState {
                watchRecordingState = watchState
                
                // Check for conflicts
                if phoneRecordingState != watchState {
                    detectAndResolveStateConflict()
                }
            }
        }
    }
    
    /// Handle watch app termination message
    private func handleWatchAppTermination(_ message: [String: Any]) {
        guard let watchStateString = message["recordingState"] as? String,
              let watchState = WatchRecordingState(rawValue: watchStateString) else {
            print("📱 Invalid watch termination message")
            return
        }
        
        print("⚠️ Watch app terminated while in state: \(watchState.rawValue)")
        
        // Update watch state
        watchRecordingState = watchState
        
        // If watch was recording, handle the emergency situation
        if watchState.isRecordingSession {
            print("🚨 Watch was recording when it terminated - entering recovery mode")
            
            // Set phone to handle the recording continuation or cleanup
            handleWatchRecordingEmergency(lastKnownState: watchState)
        }
        
        // Update connection state to reflect watch app is inactive
        connectionState = .watchAppInactive
    }
    
    /// Handle emergency when watch app terminates during recording
    private func handleWatchRecordingEmergency(lastKnownState: WatchRecordingState) {
        print("🚨 Handling watch recording emergency - last state: \(lastKnownState.rawValue)")
        
        if phoneRecordingState == .idle {
            // Legacy coordination removed - watch and phone operate independently
            print("📱 Watch recording detected but no coordinated recording needed")
        }
        
        // Notify that we're in recovery mode
        phoneRecordingState = .processing // Set to processing to indicate recovery
        sendPhoneStateToWatch(.processing)
        
        // Could implement additional recovery strategies here
        // such as attempting to start a new recording, or handling partial data
    }
    
    /// Handle phone app going to background or terminating during recording
    func handlePhoneAppTermination() {
        print("📱 Phone app terminating")
        
        // If recording, try to save final state and notify watch
        if phoneRecordingState.isRecordingSession {
            // Send emergency state update to watch
            let terminationMessage: [String: Any] = [
                "messageType": "phoneAppTerminating",
                "recordingState": phoneRecordingState.rawValue,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            session?.sendMessage(terminationMessage, replyHandler: nil) { error in
                print("⚠️ Failed to send termination message: \(error.localizedDescription)")
            }
            
            // Try to use application context for persistence
            do {
                try session?.updateApplicationContext(terminationMessage)
                print("📱 Saved termination state to application context")
            } catch {
                print("⚠️ Failed to update application context: \(error)")
            }
        }
    }
    
    /// Handle app entering background during recording
    func handleAppDidEnterBackground() {
        print("📱 Phone app entered background")
        
        if phoneRecordingState.isRecordingSession {
            // Notify watch that phone is backgrounded but continuing
            let backgroundMessage: [String: Any] = [
                "messageType": "phoneAppBackgrounded",
                "recordingState": phoneRecordingState.rawValue,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            session?.sendMessage(backgroundMessage, replyHandler: nil) { error in
                print("⚠️ Failed to send background message: \(error.localizedDescription)")
            }
        }
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
                print("📱 iPhone WCSession activated successfully")
                self.updateConnectionState()
            case .inactive:
                print("⌚ WCSession inactive")
                self.connectionState = .disconnected
            case .notActivated:
                print("⌚ WCSession not activated")
                self.connectionState = .error
            @unknown default:
                print("⌚ WCSession unknown activation state")
                self.connectionState = .error
            }
        }
    }
    
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            print("⌚ WCSession became inactive")
            self.connectionState = .disconnected
        }
    }
    
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async {
            print("⌚ WCSession deactivated")
            self.connectionState = .disconnected
        }
        
        // Reactivate session
        session.activate()
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            print("⌚ Watch reachability changed: \(session.isReachable)")
            self.updateConnectionState()
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            print("📱 iPhone received message from watch: \(message)")
            self.processWatchMessage(message)
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            print("📱 iPhone received message with reply handler from watch: \(message)")
            self.processWatchMessage(message)
            
            // Send reply with current phone status
            let reply: [String: Any] = [
                "status": "received",
                "phoneAppActive": true,
                "timestamp": Date().timeIntervalSince1970
            ]
            print("📱 iPhone sending reply: \(reply)")
            replyHandler(reply)
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            print("⌚ Received application context from watch")
            self.processWatchMessage(applicationContext)
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            print("⌚ Received user info from watch")
            self.processWatchMessage(userInfo)
        }
    }
    
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            print("⌚ User info transfer failed: \(error.localizedDescription)")
        } else {
            print("⌚ User info transfer completed successfully")
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("⌚ Received file from watch: \(file.fileURL.lastPathComponent)")
        
        DispatchQueue.main.async {
            // Check if this is a sync protocol file transfer
            if let transferType = file.metadata?["transferType"] as? String {
                if transferType == "complete_recording" || transferType == "reliable_recording" {
                    // Sync protocol file transfer (legacy or reliable)
                    self.handleWatchRecordingReceived(fileURL: file.fileURL, metadata: file.metadata ?? [:])
                } else {
                    print("⚠️ Unknown transfer type: \(transferType)")
                }
            } else {
                // Legacy file transfer no longer supported - only sync protocol
                print("⚠️ Received file transfer without transfer type - ignoring")
            }
        }
    }
}

// MARK: - Supporting Types

enum StateConflictResolution {
    case phoneWins
    case watchWins
    case mostRecentWins
    case smartResolution
}

// MARK: - Extensions

import CryptoKit

extension Data {
    var md5: String {
        let digest = Insecure.MD5.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}