//
//  WatchConnectivityManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import Foundation
@preconcurrency import WatchConnectivity
import Combine

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
    
    // State synchronization
    private var stateSyncTimer: Timer?
    private var lastWatchStateChange: Date = Date()
    private var lastPhoneStateChange: Date = Date()
    private var syncInterval: TimeInterval = 2.0 // Sync every 2 seconds
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
        // Note: State sync happens through manual triggers, not automatic timers
    }
    
    deinit {
        // Clean up session safely
        if let session = session {
            session.delegate = nil
        }
        self.session = nil
        stateSyncTimer?.invalidate()
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
        // Notify phone that watch app is active
        sendRecordingCommand(.watchAppActivated)
        
        // Request status sync
        requestSyncWithPhone()
        
        // Update connection state
        updateConnectionState()
        
        print("⌚ Watch app became active")
    }
    
    private func handleWatchAppWillResignActive() {
        // Update connection state but don't interrupt recording
        updateConnectionState()
        
        print("⌚ Watch app will resign active")
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
        
        onConnectionRestored?()
        
        // Request immediate state sync
        requestPhoneStateUpdate()
        
        // Send current watch state
        sendWatchStateToPhone(watchRecordingState)
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
            self.updateConnectionState()
            
            if session.isReachable {
                // Phone became reachable, request sync
                self.requestSyncWithPhone()
                
                if !wasReachable {
                    // Connection was restored
                    self.handleConnectionRestored()
                }
            } else {
                // Connection lost
                if wasReachable {
                    self.handleConnectionLost()
                }
            }
        }
    }
    
    /// Handle connection loss - notify audio manager and increase buffering
    private func handleConnectionLost() {
        print("⌚ Connection to phone lost")
        
        // Notify state that we're disconnected but continue recording
        if watchRecordingState.isRecordingSession {
            updateWatchRecordingState(watchRecordingState) // Trigger state sync attempt
        }
        
        // If we have a watch audio manager, notify it
        // This would typically be connected through the WatchRecordingViewModel
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
            Task { @MainActor in
                self.onAudioTransferCompleted?(false)
            }
        } else {
            print("⌚ File transfer completed successfully")
            Task { @MainActor in
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
}