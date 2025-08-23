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

/// Manages WatchConnectivity session and communication with iPhone
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var connectionState: WatchConnectionState = .disconnected
    @Published var isPhoneAppActive: Bool = false
    @Published var lastPhoneMessage: String = ""
    @Published var phoneRecordingState: WatchRecordingState = .idle
    @Published var isTransferringAudio: Bool = false
    @Published var audioTransferProgress: Double = 0.0
    
    // State synchronization
    @Published var watchRecordingState: WatchRecordingState = .idle
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
    private var currentRecordingSessionId: UUID?
    private var audioChunksToSend: [WatchAudioChunk] = []
    private var chunkTransferIndex: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    // File transfer tracking
    private var activeFileTransfers: [String: WCSessionFileTransfer] = [:]
    private var fileTransferCompletions: [String: (Bool) -> Void] = [:]
    private var transferStartTimes: [String: Date] = [:]
    
    // Reliable transfer system
    private var reliableTransfers: [UUID: ReliableTransfer] = [:]
    private var retryTimer: Timer?
    private let retryCheckInterval: TimeInterval = 30.0
    
    // State synchronization
    private var stateSyncTimer: Timer?
    private var lastWatchStateChange: Date = Date()
    private var lastPhoneStateChange: Date = Date()
    private var syncInterval: TimeInterval = 2.0 // Sync every 2 seconds
    
    // Connectivity debouncing and deduplication
    private var connectivityDebounceTimer: Timer?
    private let connectivityDebounceDelay: TimeInterval = 2.0
    private var lastReachabilityChange: Date = Date()
    private var pendingSyncRequests: Set<String> = []
    private var lastSyncRequestTime: Date?
    private let minSyncRequestInterval: TimeInterval = 3.0
    private var isRecoveringConnection = false
    private var conflictResolutionStrategy: StateConflictResolution = .smartResolution
    
    // MARK: - Callbacks for WatchRecordingViewModel integration
    var onPhoneRecordingStateChanged: ((WatchRecordingState) -> Void)?
    var onPhoneAppActivated: (() -> Void)?
    var onPhoneErrorReceived: ((WatchErrorMessage) -> Void)?
    var onAudioTransferCompleted: ((Bool) -> Void)?
    
    // State synchronization callbacks
    var onStateConflictDetected: ((WatchRecordingState, WatchRecordingState) -> Void)? // watch state, phone state
    var onStateSyncCompleted: (() -> Void)?
    var onConnectionRestored: (() -> Void)?
    
    // MARK: - Singleton
    static let shared = WatchConnectivityManager()
    
    override init() {
        super.init()
        setupWatchConnectivity()
        setupNotificationObservers()
        loadReliableTransfers()
        startRetryTimer()
        // Note: State sync happens through manual triggers, not automatic timers
    }
    
    deinit {
        // Clean up session safely
        if let session = session {
            session.delegate = nil
        }
        self.session = nil
        stateSyncTimer?.invalidate()
        retryTimer?.invalidate()
        
        // Note: Cannot safely save reliable transfers in deinit due to MainActor isolation
        // The system will load persisted transfers on next app launch
        print("⌚ WatchConnectivityManager deinit - transfers will be saved on next state change")
    }
    
    // MARK: - Setup Methods
    
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            print("⌚ WatchConnectivity not supported on this device")
            connectionState = .error
            return
        }
        
        // Initialize session safely
        let wcSession = WCSession.default
        self.session = wcSession
        wcSession.activate()
        
        print("⌚ Watch WatchConnectivity session setup initiated")
    }
    
    private func setupNotificationObservers() {
        // Listen for watch app lifecycle events
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
    
    /// Send recording command to phone
    func sendRecordingCommand(_ message: WatchRecordingMessage, additionalInfo: [String: Any]? = nil) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot send recording command - session not available or not activated")
            return
        }
        
        // If phone app is not reachable and this is a recording command (not sync/status), try to activate it first
        if !session.isReachable && message != .phoneAppActivated && message != .requestSync && message != .recordingStatusUpdate {
            activatePhoneApp()
            
            // Queue the command to send after activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if session.isReachable {
                    session.sendRecordingMessage(message, userInfo: additionalInfo)
                    print("⌚ Sent recording command to phone after activation: \(message.rawValue)")
                } else {
                    print("⌚ Failed to activate phone app for recording command")
                    self.connectionState = .phoneAppInactive
                }
            }
        } else {
            session.sendRecordingMessage(message, userInfo: additionalInfo)
            print("⌚ Sent recording command to phone: \(message.rawValue)")
        }
    }
    
    /// Send current watch recording status to phone
    func sendRecordingStatusToPhone(_ state: WatchRecordingState, recordingTime: TimeInterval, error: String? = nil) {
        let batteryLevel = getBatteryLevel()
        let statusUpdate = WatchRecordingStatusUpdate(
            state: state,
            recordingTime: recordingTime,
            batteryLevel: batteryLevel,
            errorMessage: error
        )
        
        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot send status update - session not available")
            return
        }
        session.sendStatusUpdate(statusUpdate)
        print("⌚ Sent status update to phone: \(state.rawValue)")
    }
    
    /// Start audio transfer to phone
    func startAudioTransfer(sessionId: UUID, audioChunks: [WatchAudioChunk]) {
        currentRecordingSessionId = sessionId
        audioChunksToSend = audioChunks
        chunkTransferIndex = 0
        isTransferringAudio = true
        audioTransferProgress = 0.0
        
        print("⌚ Starting audio transfer: \(audioChunks.count) chunks")
        transferNextAudioChunk()
    }
    
    /// Transfer a single audio chunk immediately (for live streaming during recording)
    func transferSingleChunk(_ chunk: WatchAudioChunk, completion: @escaping (Bool, Error?) -> Void) {
        guard let session = session, session.activationState == .activated else {
            let error = WatchConnectivityError.sessionNotAvailable
            completion(false, error)
            return
        }
        
        guard session.isReachable else {
            let error = WatchConnectivityError.phoneNotReachable
            completion(false, error)
            return
        }
        
        let chunkDict = chunk.toDictionary()
        
        // Add message type
        var messageDict = WatchRecordingMessage.audioChunkTransfer.userInfo
        messageDict.merge(chunkDict) { _, new in new }
        
        session.sendMessage(messageDict, replyHandler: { reply in
            Task { @MainActor in
                print("⌚ Chunk \(chunk.sequenceNumber) transferred successfully")
                completion(true, nil)
            }
        }, errorHandler: { error in
            Task { @MainActor in
                print("⌚ Chunk \(chunk.sequenceNumber) transfer failed: \(error.localizedDescription)")
                completion(false, error)
            }
        })
    }
    
    /// Request sync with phone app
    func requestSyncWithPhone() {
        guard let session = session, session.isReachable else {
            return
        }
        sendRecordingCommand(.requestSync)
    }
    
    /// Request phone app activation for recording
    func requestPhoneAppActivation() {
        guard let session = session, session.activationState == .activated else { 
            print("⌚ Cannot request phone app activation - session not available")
            return 
        }
        
        print("⌚ Requesting iPhone app activation...")
        
        // Send activation request directly without going through sendRecordingCommand
        // to avoid infinite recursion with automatic activation logic
        let activationMessage: [String: Any] = [
            "messageType": WatchRecordingMessage.requestPhoneAppActivation.rawValue,
            "timestamp": Date().timeIntervalSince1970,
            "requestType": "activateForRecording"
        ]
        
        if session.isReachable {
            session.sendMessage(activationMessage, replyHandler: nil) { error in
                print("⌚ Failed to send activation message: \(error.localizedDescription)")
            }
            print("⌚ Sent phone app activation request via message")
        }
        
        // Also use application context for background wake-up
        let context: [String: Any] = [
            "requestType": "activateForRecording",
            "timestamp": Date().timeIntervalSince1970,
            "watchAppActive": true
        ]
        
        do {
            try session.updateApplicationContext(context)
            print("⌚ Sent phone app activation request via context")
        } catch {
            print("⌚ Failed to send activation context: \(error.localizedDescription)")
        }
    }
    
    /// Legacy method - kept for compatibility
    func activatePhoneApp() {
        requestPhoneAppActivation()
    }
    
    // MARK: - State Synchronization
    
    /// Update the watch recording state and sync with phone
    func updateWatchRecordingState(_ newState: WatchRecordingState) {
        guard watchRecordingState != newState else { return }
        
        let previousState = watchRecordingState
        watchRecordingState = newState
        lastWatchStateChange = Date()
        lastStateSyncTime = Date()
        
        print("⌚ Watch state changed: \(previousState.rawValue) → \(newState.rawValue)")
        
        // Send state update to phone immediately
        sendWatchStateToPhone(newState)
        
        // Check for conflicts
        if phoneRecordingState != newState && connectionState.isConnected {
            detectAndResolveStateConflict()
        }
    }
    
    /// Send current watch recording state to phone
    private func sendWatchStateToPhone(_ state: WatchRecordingState) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ Cannot send state - session not available")
            return
        }
        
        let stateMessage: [String: Any] = [
            "messageType": "watchStateUpdate",
            "recordingState": state.rawValue,
            "timestamp": lastWatchStateChange.timeIntervalSince1970,
            "batteryLevel": getBatteryLevel(),
            "sessionId": currentRecordingSessionId?.uuidString ?? ""
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
            print("⌚ Phone not reachable, will sync state when connected")
        }
    }
    
    /// Handle reply from phone after state update
    private func handleStateUpdateReply(_ reply: [String: Any]) {
        if let phoneStateString = reply["phoneRecordingState"] as? String,
           let phoneState = WatchRecordingState(rawValue: phoneStateString),
           let timestamp = reply["timestamp"] as? TimeInterval {
            
            lastPhoneStateChange = Date(timeIntervalSince1970: timestamp)
            
            if phoneRecordingState != phoneState {
                phoneRecordingState = phoneState
                print("⌚ Received phone state update: \(phoneState.rawValue)")
                
                // Check for conflicts
                if watchRecordingState != phoneState {
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
        print("⌚ Started state synchronization (interval: \(syncInterval)s)")
    }
    
    /// Perform periodic state synchronization
    private func performPeriodicStateSync() {
        guard connectionState.isConnected else { return }
        
        // Send current state as heartbeat
        sendWatchStateToPhone(watchRecordingState)
        
        // Check if we haven't heard from phone in a while
        let phoneStateAge = Date().timeIntervalSince(lastPhoneStateChange)
        if phoneStateAge > (syncInterval * 5) { // Increased from 3 to 5 (10 seconds instead of 6)
            print("📱 Requesting phone state sync (last update: \(Int(phoneStateAge))s ago)")
            requestPhoneStateUpdate()
        }
    }
    
    /// Request current state from phone
    private func requestPhoneStateUpdate() {
        guard let session = session, session.activationState == .activated, session.isReachable else {
            return
        }
        
        let requestMessage: [String: Any] = [
            "messageType": "requestStateSync",
            "watchState": watchRecordingState.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session.sendMessage(requestMessage, replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.handleStateUpdateReply(reply)
            }
        }) { error in
            print("❌ Failed to request phone state: \(error.localizedDescription)")
        }
    }
    
    /// Detect and resolve state conflicts between watch and phone
    private func detectAndResolveStateConflict() {
        guard watchRecordingState != phoneRecordingState else {
            stateConflictDetected = false
            return
        }
        
        print("⚠️ State conflict detected - Watch: \(watchRecordingState.rawValue), Phone: \(phoneRecordingState.rawValue)")
        stateConflictDetected = true
        
        onStateConflictDetected?(watchRecordingState, phoneRecordingState)
        
        // Apply conflict resolution strategy
        resolveStateConflict()
    }
    
    /// Resolve state conflict based on strategy
    private func resolveStateConflict() {
        let resolution = determineConflictResolution()
        
        switch resolution {
        case .phoneWins:
            print("🔄 Resolving conflict: Phone wins, updating watch state to \(phoneRecordingState.rawValue)")
            watchRecordingState = phoneRecordingState
            onPhoneRecordingStateChanged?(phoneRecordingState)
            
        case .watchWins:
            print("🔄 Resolving conflict: Watch wins, sending watch state to phone")
            sendWatchStateToPhone(watchRecordingState)
            
        case .mostRecentWins:
            if lastWatchStateChange > lastPhoneStateChange {
                print("🔄 Resolving conflict: Watch state is more recent")
                sendWatchStateToPhone(watchRecordingState)
            } else {
                print("🔄 Resolving conflict: Phone state is more recent")
                watchRecordingState = phoneRecordingState
                onPhoneRecordingStateChanged?(phoneRecordingState)
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
        if watchRecordingState.isRecordingSession || phoneRecordingState.isRecordingSession {
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
        
        if watchRecordingState == .recording && phoneRecordingState != .recording {
            print("🧠 Smart resolution: Watch is actively recording, watch wins")
            sendWatchStateToPhone(watchRecordingState)
        } else if phoneRecordingState == .recording && watchRecordingState != .recording {
            print("🧠 Smart resolution: Phone is actively recording, phone wins")
            watchRecordingState = phoneRecordingState
            onPhoneRecordingStateChanged?(phoneRecordingState)
        } else if watchRecordingState == .error || phoneRecordingState == .error {
            print("🧠 Smart resolution: Error state detected, syncing to error")
            let errorState: WatchRecordingState = .error
            if watchRecordingState != errorState {
                watchRecordingState = errorState
            }
            sendWatchStateToPhone(errorState)
        } else if watchRecordingState == .processing || phoneRecordingState == .processing {
            print("🧠 Smart resolution: Processing state detected, maintaining processing")
            let processingState: WatchRecordingState = .processing
            if watchRecordingState != processingState {
                watchRecordingState = processingState
            }
            sendWatchStateToPhone(processingState)
        } else {
            // Fall back to most recent change
            if lastWatchStateChange > lastPhoneStateChange {
                sendWatchStateToPhone(watchRecordingState)
            } else {
                watchRecordingState = phoneRecordingState
                onPhoneRecordingStateChanged?(phoneRecordingState)
            }
        }
    }
    
    // MARK: - App Lifecycle Handlers
    
    private func handleWatchAppBecameActive() {
        let wasRecording = isRecordingInProgress()
        
        if wasRecording {
            print("⌚ Watch app became active (was recording - minimal sync)")
            // During recording, minimize connectivity operations to avoid interruption
            updateConnectionState()
        } else {
            print("⌚ Watch app became active (normal sync)")
            // Notify phone that watch app is active
            sendRecordingCommand(.watchAppActivated)
            
            // Request status sync
            requestSyncWithPhone()
            
            // Update connection state
            updateConnectionState()
        }
    }
    
    private func handleWatchAppWillResignActive() {
        let isRecording = isRecordingInProgress()
        
        if isRecording {
            print("⌚ Watch app will resign active (recording in progress - preserving session)")
            // Don't perform heavy sync operations during recording
            // Audio recording will continue in background
        } else {
            print("⌚ Watch app will resign active (normal)")
            // Update connection state for non-recording scenarios
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
        
        // Handle connection restoration
        if previousState != .connected && connectionState == .connected {
            handleConnectionRestored()
        }
    }
    
    /// Handle connection restoration - trigger state recovery
    private func handleConnectionRestored() {
        print("⌚ Connection restored, performing state recovery")
        
        // Prevent multiple recovery operations
        guard !isRecoveringConnection else {
            print("⌚ Already recovering connection, skipping duplicate recovery")
            return
        }
        
        isRecoveringConnection = true
        
        // Clear any stale sync requests
        pendingSyncRequests.removeAll()
        
        onConnectionRestored?()
        
        // Retry reliable transfers
        retryReliableTransfers()
        
        // Request sync with throttling instead of immediate requests
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.requestSyncWithPhoneThrottled()
            
            // Request phone state update with throttling
            self?.requestPhoneStateUpdate()
            
            // Send current watch state
            self?.sendWatchStateToPhone(self?.watchRecordingState ?? .idle)
            
            self?.isRecoveringConnection = false
        }
    }
    
    // MARK: - Audio Transfer Methods
    
    private func transferNextAudioChunk() {
        guard chunkTransferIndex < audioChunksToSend.count else {
            // All chunks transferred
            completeAudioTransfer()
            return
        }
        
        let chunk = audioChunksToSend[chunkTransferIndex]
        let chunkDict = chunk.toDictionary()
        
        // Add message type
        var messageDict = WatchRecordingMessage.audioChunkTransfer.userInfo
        messageDict.merge(chunkDict) { _, new in new }
        
        session?.sendMessage(messageDict, replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.handleChunkTransferReply(reply)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.handleChunkTransferError(error)
            }
        })
        
        print("⌚ Transferred audio chunk \(chunkTransferIndex + 1)/\(audioChunksToSend.count)")
        
        chunkTransferIndex += 1
        audioTransferProgress = Double(chunkTransferIndex) / Double(audioChunksToSend.count)
    }
    
    private func handleChunkTransferReply(_ reply: [String: Any]) {
        // Phone confirmed receipt, send next chunk
        transferNextAudioChunk()
    }
    
    private func handleChunkTransferError(_ error: Error) {
        print("❌ Audio chunk transfer failed: \(error.localizedDescription)")
        
        // Retry once
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.chunkTransferIndex > 0 {
                self.chunkTransferIndex -= 1 // Retry last chunk
                self.transferNextAudioChunk()
            }
        }
    }
    
    private func completeAudioTransfer() {
        isTransferringAudio = false
        audioTransferProgress = 1.0
        
        // Send completion notification
        let completionInfo: [String: Any] = [
            "sessionId": currentRecordingSessionId?.uuidString ?? "",
            "totalChunks": audioChunksToSend.count,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        sendRecordingCommand(.audioTransferComplete, additionalInfo: completionInfo)
        
        print("✅ Audio transfer completed: \(audioChunksToSend.count) chunks")
        
        // Cleanup
        audioChunksToSend.removeAll()
        chunkTransferIndex = 0
        currentRecordingSessionId = nil
        
        // Notify completion
        onAudioTransferCompleted?(true)
    }
    
    // MARK: - Utility Methods
    
    private func getBatteryLevel() -> Float {
        #if canImport(WatchKit)
        return WKInterfaceDevice.current().batteryLevel
        #else
        return 1.0 // Fallback for non-watchOS platforms
        #endif
    }
    
    private func sendErrorToPhone(_ errorType: WatchErrorType, message: String) {
        let errorMessage = WatchErrorMessage(
            errorType: errorType,
            message: message,
            deviceType: .appleWatch
        )
        
        session?.sendErrorMessage(errorMessage)
    }
    
    // MARK: - Message Processing
    
    private func processPhoneMessage(_ message: [String: Any]) {
        guard let messageTypeString = message["messageType"] as? String else {
            print("⌚ No message type in received message")
            return
        }
        
        // Handle state synchronization messages first
        if messageTypeString == "phoneStateUpdate" {
            handlePhoneStateUpdate(message)
            return
        } else if messageTypeString == "requestStateSync" {
            handleStateSync(message)
            return
        }
        
        // Handle standard WatchRecordingMessage types
        guard let messageType = WatchRecordingMessage(rawValue: messageTypeString) else {
            print("⌚ Unknown message type received from phone: \(messageTypeString)")
            return
        }
        
        lastPhoneMessage = messageType.rawValue
        
        switch messageType {
        case .recordingStatusUpdate:
            if let statusUpdate = WatchRecordingStatusUpdate.fromDictionary(message) {
                phoneRecordingState = statusUpdate.state
                print("⌚ Phone status update: \(statusUpdate.state.rawValue)")
                onPhoneRecordingStateChanged?(statusUpdate.state)
            }
            
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
            
        case .audioTransferComplete:
            print("⌚ Phone confirmed audio transfer complete")
            onAudioTransferCompleted?(true)
            
        case .chunkAcknowledgment:
            if let chunkId = message["chunkId"] as? String {
                print("⌚ Phone acknowledged chunk: \(chunkId)")
                // Handle chunk acknowledgment for real-time transfer tracking
            }
            
        case .connectionStatusUpdate:
            updateConnectionState()
            
        case .requestSync:
            print("⌚ Phone requested sync")
            // Send current watch status
            // This will be handled by WatchRecordingViewModel
            
        // These are commands we send, not receive
        case .startRecording, .stopRecording, .pauseRecording, .resumeRecording:
            break
        case .audioChunkTransfer:
            break
        case .watchAppActivated:
            break
        case .requestPhoneAppActivation:
            // This is sent by watch to phone, not received
            break
            
        // MARK: - New sync protocol message handling
        case .appReadinessResponse:
            if let response = WatchAppReadinessResponse.fromDictionary(message) {
                handleAppReadinessResponse(response)
            }
            
        case .syncAccepted, .syncRejected:
            if let response = WatchSyncResponse.fromDictionary(message) {
                handleSyncResponse(response)
            }
            
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
            
        // These are sent by watch, not processed here
        case .checkAppReadiness, .syncRequest, .fileTransferStart, .fileReceived, .metadataTransfer, .coreDataCreated:
            break
        }
    }
    
    /// Handle phone state update message
    private func handlePhoneStateUpdate(_ message: [String: Any]) {
        guard let phoneStateString = message["recordingState"] as? String,
              let phoneState = WatchRecordingState(rawValue: phoneStateString),
              let timestamp = message["timestamp"] as? TimeInterval else {
            print("⌚ Invalid phone state update message")
            return
        }
        
        lastPhoneStateChange = Date(timeIntervalSince1970: timestamp)
        
        if phoneRecordingState != phoneState {
            let previousPhoneState = phoneRecordingState
            phoneRecordingState = phoneState
            print("⌚ Phone state updated: \(previousPhoneState.rawValue) → \(phoneState.rawValue)")
            
            onPhoneRecordingStateChanged?(phoneState)
            
            // Check for conflicts
            if watchRecordingState != phoneState {
                detectAndResolveStateConflict()
            }
        }
    }
    
    /// Handle state sync request from phone
    private func handleStateSync(_ message: [String: Any]) {
        print("⌚ Phone requested state sync")
        
        // Send current watch state immediately
        sendWatchStateToPhone(watchRecordingState)
        
        // If phone state is included, update it
        if let phoneStateString = message["phoneState"] as? String,
           let phoneState = WatchRecordingState(rawValue: phoneStateString),
           let timestamp = message["timestamp"] as? TimeInterval {
            
            lastPhoneStateChange = Date(timeIntervalSince1970: timestamp)
            
            if phoneRecordingState != phoneState {
                phoneRecordingState = phoneState
                onPhoneRecordingStateChanged?(phoneState)
                
                // Check for conflicts
                if watchRecordingState != phoneState {
                    detectAndResolveStateConflict()
                }
            }
        }
    }
    
    // MARK: - New Sync Protocol Message Handlers
    
    private func handleAppReadinessResponse(_ response: WatchAppReadinessResponse) {
        print("⌚ Received app readiness response: \(response.ready ? "ready" : "not ready") - \(response.reason)")
        
        // Forward to view model via notification (could also use callbacks)
        NotificationCenter.default.post(
            name: Notification.Name("WatchAppReadinessResponse"),
            object: response
        )
    }
    
    private func handleSyncResponse(_ response: WatchSyncResponse) {
        print("⌚ Received sync response: \(response.accepted ? "accepted" : "rejected")")
        
        // Forward to view model
        NotificationCenter.default.post(
            name: Notification.Name("WatchSyncResponse"),
            object: response
        )
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
    
    // MARK: - File Transfer Methods
    
    /// Transfer complete recording file to iPhone with reliability
    func transferCompleteRecording(fileURL: URL, metadata: WatchRecordingMetadata, completion: @escaping (Bool) -> Void) {
        // Add to reliable transfer queue
        let reliableTransfer = ReliableTransfer(from: metadata, fileURL: fileURL)
        reliableTransfers[reliableTransfer.recordingId] = reliableTransfer
        saveReliableTransfers()
        
        print("⌚ Added reliable transfer: \(metadata.filename)")
        
        // Attempt immediate transfer if connected
        attemptReliableTransfer(reliableTransfer.recordingId)
        
        // Always call completion - reliable system will handle the actual transfer
        completion(true)
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
        let transferMetadata: [String: Any] = [
            "transferType": "reliable_recording",
            "recordingId": transfer.recordingId.uuidString,
            "reliableTransferId": transfer.id.uuidString,
            "filename": transfer.filename,
            "duration": transfer.duration,
            "fileSize": transfer.fileSize,
            "createdAt": transfer.createdAt.timeIntervalSince1970,
            "retryCount": transfer.retryCount
        ]
        
        // Start file transfer
        let fileTransfer: WCSessionFileTransfer = session.transferFile(transfer.fileURL, metadata: transferMetadata)
        let transferKey = transfer.recordingId.uuidString
        
        // Store transfer tracking info
        activeFileTransfers[transferKey] = fileTransfer
        transferStartTimes[transferKey] = Date()
        
        // Set transfer status to awaiting confirmation once started
        transfer.status = .awaitingConfirmation
        reliableTransfers[recordingId] = transfer
        saveReliableTransfers()
    }
    
    /// Estimate transfer time based on file size and connection quality
    private func estimateTransferTime(fileSizeMB: Double) -> TimeInterval {
        // Base estimates for WatchConnectivity over Bluetooth
        let baseSpeed: Double // MB/s
        
        if let session = session, session.isReachable {
            // iPhone is reachable and active
            baseSpeed = 0.5 // ~0.5 MB/s typical for active connection
        } else {
            // iPhone may be backgrounded or connection quality poor
            baseSpeed = 0.2 // ~0.2 MB/s for poor/backgrounded connection
        }
        
        let estimatedTime = fileSizeMB / baseSpeed
        
        // Add overhead for protocol and processing
        let overhead = max(5.0, estimatedTime * 0.3) // 30% overhead, minimum 5s
        
        return estimatedTime + overhead
    }
    
    /// Check current connection quality and suggest optimizations
    func getConnectionDiagnostics() -> String {
        guard let session = session else {
            return "❌ WatchConnectivity session not available"
        }
        
        var diagnostics: [String] = []
        
        // Session state
        switch session.activationState {
        case .activated:
            diagnostics.append("✅ Session activated")
        case .inactive:
            diagnostics.append("⚠️ Session inactive")
        case .notActivated:
            diagnostics.append("❌ Session not activated")
        @unknown default:
            diagnostics.append("❓ Unknown session state")
        }
        
        // Reachability
        if session.isReachable {
            diagnostics.append("✅ iPhone reachable")
        } else {
            diagnostics.append("❌ iPhone not reachable (may be backgrounded)")
        }
        
        // Check for outstanding transfers
        if !session.outstandingFileTransfers.isEmpty {
            diagnostics.append("⚠️ \(session.outstandingFileTransfers.count) transfers already queued")
        } else {
            diagnostics.append("✅ No queued transfers")
        }
        
        // Performance recommendations
        if !session.isReachable {
            diagnostics.append("💡 Tip: Keep iPhone app in foreground for faster transfers")
        }
        
        if session.outstandingFileTransfers.count > 1 {
            diagnostics.append("💡 Tip: Wait for current transfer to complete before starting new ones")
        }
        
        return diagnostics.joined(separator: "\n")
    }
    
    // MARK: - Reliable Transfer Management
    
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
        
        // Mark as confirmed
        transfer.recordSuccess()
        print("✅ Reliable transfer confirmed: \(transfer.filename)")
        
        // NOW it's safe to delete the local file
        do {
            try FileManager.default.removeItem(at: transfer.fileURL)
            print("🗁️ Deleted local file after confirmation: \(transfer.filename)")
        } catch {
            print("⚠️ Failed to delete local file: \(error)")
        }
        
        // Remove from reliable transfers
        reliableTransfers.removeValue(forKey: recordingId)
        saveReliableTransfers()
        
        print("✅ Reliable transfer completed and cleaned up: \(transfer.filename)")
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
                
                // Verify file still exists
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
                
                // Note: Sync will happen when view appears, no need for automatic sync here
                
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
            
            // Record the reachability change time
            self.lastReachabilityChange = Date()
            
            // Cancel any existing debounce timer
            self.connectivityDebounceTimer?.invalidate()
            
            // Debounce connectivity changes to prevent rapid state changes
            self.connectivityDebounceTimer = Timer.scheduledTimer(withTimeInterval: self.connectivityDebounceDelay, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleDebouncedReachabilityChange(session: session, wasReachable: wasReachable)
                }
            }
        }
    }
    
    /// Handle connection loss - notify audio manager and increase buffering
    private func handleConnectionLost() {
        print("⌚ Connection to phone lost")
        
        // Clear recovery flag and pending requests
        isRecoveringConnection = false
        pendingSyncRequests.removeAll()
        
        // Notify state that we're disconnected but continue recording
        if watchRecordingState.isRecordingSession {
            updateWatchRecordingState(watchRecordingState) // Trigger state sync attempt
        }
        
        // If we have a watch audio manager, notify it
        // This would typically be connected through the WatchRecordingViewModel
    }
    
    /// Handle debounced reachability changes with proper deduplication
    private func handleDebouncedReachabilityChange(session: WCSession, wasReachable: Bool) {
        print("⌚ Processing debounced reachability change: \(session.isReachable)")
        updateConnectionState()
        
        if session.isReachable {
            if !wasReachable {
                // Connection was restored
                handleConnectionRestored()
            }
            // Request sync with throttling
            requestSyncWithPhoneThrottled()
        } else {
            // Connection lost
            if wasReachable {
                handleConnectionLost()
            }
        }
    }
    
    
    /// Request sync with phone using throttling and deduplication
    private func requestSyncWithPhoneThrottled() {
        // Don't attempt sync if session isn't reachable
        guard let session = session, session.isReachable else {
            return
        }
        
        let currentTime = Date()
        let requestId = "sync_\(Int(currentTime.timeIntervalSince1970))"
        
        // Check if we have a recent sync request
        if let lastSync = lastSyncRequestTime,
           currentTime.timeIntervalSince(lastSync) < minSyncRequestInterval {
            print("⌚ Throttling sync request - too recent")
            return
        }
        
        // Check for duplicate requests
        if pendingSyncRequests.contains(requestId) {
            print("⌚ Duplicate sync request ignored")
            return
        }
        
        // Add to pending requests
        pendingSyncRequests.insert(requestId)
        lastSyncRequestTime = currentTime
        
        // Send the sync request
        session.sendRecordingMessage(.requestSync)
        
        // Clean up pending requests after timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.pendingSyncRequests.remove(requestId)
        }
        
        print("⌚ Sent throttled sync request: \(requestId)")
    }
    
    /// Handle app termination scenarios
    func handleAppTermination() {
        print("⌚ Watch app terminating")
        
        // If recording, try to save final state
        if watchRecordingState.isRecordingSession {
            // Send emergency state update
            let terminationMessage: [String: Any] = [
                "messageType": "watchAppTerminating",
                "recordingState": watchRecordingState.rawValue,
                "timestamp": Date().timeIntervalSince1970,
                "pendingChunks": 0 // Could track actual pending chunks
            ]
            
            session?.sendMessage(terminationMessage, replyHandler: nil) { error in
                print("⚠️ Failed to send termination message: \(error.localizedDescription)")
            }
            
            // Try to use application context for persistence
            do {
                try session?.updateApplicationContext(terminationMessage)
            } catch {
                print("⚠️ Failed to update application context: \(error)")
            }
        }
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
            let batteryLevel = self.getBatteryLevel()
            let reply: [String: Any] = [
                "status": "received",
                "watchAppActive": true,
                "batteryLevel": batteryLevel,
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
    
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            print("⌚ User info transfer failed: \(error.localizedDescription)")
        } else {
            print("⌚ User info transfer completed successfully")
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("⌚ Received file from phone: \(file.fileURL.lastPathComponent)")
        // Handle any files sent from phone (unlikely in this use case)
    }
    
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error = error {
            print("⌚ File transfer failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onAudioTransferCompleted?(false)
            }
        } else {
            print("⌚ File transfer completed successfully")
            DispatchQueue.main.async {
                self.onAudioTransferCompleted?(true)
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

// MARK: - Reliable Transfer Types

/// Status of a reliable transfer
enum ReliableTransferStatus: String, Codable {
    case pending = "pending"
    case transferring = "transferring"
    case awaitingConfirmation = "awaiting_confirmation"
    case confirmed = "confirmed"
    case failed = "failed"
    
    var canRetry: Bool {
        switch self {
        case .pending, .failed: return true
        case .transferring, .awaitingConfirmation, .confirmed: return false
        }
    }
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
        
        // Calculate checksum from file data
        self.checksumMD5 = Self.calculateMD5(for: fileURL)
        
        self.status = .pending
        self.retryCount = 0
        self.lastAttemptTime = Date()
        self.failureReason = nil
    }
    
    var shouldRetry: Bool {
        guard status.canRetry && retryCount < 5 else { return false }
        
        let timeSinceLastAttempt = Date().timeIntervalSince(lastAttemptTime)
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

enum WatchConnectivityError: LocalizedError {
    case sessionNotAvailable
    case phoneNotReachable
    case transferFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .sessionNotAvailable:
            return "WatchConnectivity session not available"
        case .phoneNotReachable:
            return "Phone app is not reachable"
        case .transferFailed(let message):
            return "Transfer failed: \(message)"
        }
    }
    
    // MARK: - New Sync Protocol Message Handlers
    
    private func handleAppReadinessResponse(_ response: WatchAppReadinessResponse) {
        print("⌚ Received app readiness response: \(response.ready ? "ready" : "not ready") - \(response.reason)")
        
        // Forward to view model via notification (could also use callbacks)
        NotificationCenter.default.post(
            name: Notification.Name("WatchAppReadinessResponse"),
            object: response
        )
    }
}