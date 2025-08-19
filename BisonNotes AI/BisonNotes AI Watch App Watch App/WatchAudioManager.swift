//
//  WatchAudioManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/17/25.
//

import Foundation
import AVFoundation
import Combine

#if canImport(WatchKit)
import WatchKit
#endif

/// Manages audio recording functionality on Apple Watch with battery optimization
@MainActor
class WatchAudioManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isRecording: Bool = false
    @Published var isPaused: Bool = false
    @Published var recordingTime: TimeInterval = 0
    @Published var batteryLevel: Float = 1.0
    // Audio quality matches iOS app whisperOptimized settings
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioSession: AVAudioSession?
    private var recordingTimer: Timer?
    private var chunkTimer: Timer? // New timer for real-time chunking
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var lastPauseTime: Date?
    
    // Audio chunks for transfer to phone
    private var audioChunks: [WatchAudioChunk] = []
    private var currentSessionId: UUID?
    private var chunkSequenceNumber: Int = 0
    
    // Audio buffering for chunk creation
    private var audioBuffer: Data = Data()
    private let targetChunkSize: Int = 32000  // 1 second at 16kHz, 16-bit, mono
    private var lastChunkTime: TimeInterval = 0
    
    // FileHandle optimization for efficient reading
    private var recordingFileHandle: FileHandle?
    private var lastReadPosition: UInt64 = 44 // Start after WAV header
    private var cachedBytesPerSecond: Int?
    
    // Chunk buffering for connectivity issues
    private var pendingChunks: [WatchAudioChunk] = []
    private var maxBufferedChunks: Int = 10  // Buffer up to 10 chunks (~10 seconds)
    private var retryTimer: Timer?
    private var retryAttempts: [UUID: Int] = [:]
    private var maxRetryAttempts: Int = 3
    
    // Battery and performance monitoring
    private var initialBatteryLevel: Float = 1.0
    private var maxRecordingDuration: TimeInterval = 7200 // 2 hours to match iOS app
    
    // MARK: - Callbacks
    var onRecordingStateChanged: ((Bool, Bool) -> Void)? // isRecording, isPaused
    var onAudioChunkReady: ((WatchAudioChunk) -> Void)?
    var onRecordingCompleted: (([WatchAudioChunk]) -> Void)?
    var onError: ((WatchAudioError) -> Void)?
    var onChunkTransferFailed: ((WatchAudioChunk, Error) -> Void)?
    var onChunkBuffered: ((Int) -> Void)? // number of buffered chunks
    var onConnectionLost: (() -> Void)?
    var onConnectionRestored: (() -> Void)?
    
    override init() {
        super.init()
        setupAudioSession()
        monitorBatteryLevel()
    }
    
    deinit {
        // Can't call async methods in deinit, just clean up timers and file handles
        recordingTimer?.invalidate()
        retryTimer?.invalidate()
        recordingFileHandle?.closeFile()
        audioRecorder?.stop()
    }
    
    // MARK: - Public Interface
    
    /// Start audio recording
    func startRecording() -> Bool {
        guard !isRecording else {
            print("⌚ Already recording")
            return false
        }
        
        // Check battery level
        guard canStartRecording() else {
            let error = WatchAudioError.batteryTooLow("Battery level too low to start recording")
            onError?(error)
            errorMessage = error.localizedDescription
            return false
        }
        
        // Request permission and setup recording
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if granted {
                    self.setupAndStartRecording()
                } else {
                    let error = WatchAudioError.permissionDenied("Microphone permission denied")
                    self.onError?(error)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        
        return true
    }
    
    /// Stop audio recording
    func stopRecording() {
        guard isRecording || isPaused else { return }
        
        audioRecorder?.stop()
        stopAllTimers()
        
        isRecording = false
        isPaused = false
        
        // Note: Don't reset recordingTime here, we need it for finalization
        // Don't call finalizeRecording() here - it will be called by the delegate
        
        onRecordingStateChanged?(false, false)
        print("⌚ Recording stopped")
    }
    
    /// Pause audio recording
    func pauseRecording() {
        guard isRecording && !isPaused else { return }
        
        audioRecorder?.pause()
        isPaused = true
        lastPauseTime = Date()
        
        // Pause timers but keep level monitoring
        recordingTimer?.invalidate()
        
        onRecordingStateChanged?(true, true)
        print("⌚ Recording paused")
    }
    
    /// Resume audio recording
    func resumeRecording() {
        guard isRecording && isPaused else { return }
        
        // Calculate paused duration
        if let pauseTime = lastPauseTime {
            pausedDuration += Date().timeIntervalSince(pauseTime)
        }
        
        audioRecorder?.record()
        isPaused = false
        lastPauseTime = nil
        
        // Resume timers
        startRecordingTimer()
        
        onRecordingStateChanged?(true, false)
        print("⌚ Recording resumed")
    }
    
    /// Get current recording session ID
    func getCurrentSessionId() -> UUID? {
        return currentSessionId
    }
    
    /// Get all recorded audio chunks
    func getAudioChunks() -> [WatchAudioChunk] {
        return audioChunks
    }
    
    /// Get number of chunks waiting to be transferred
    func getPendingChunkCount() -> Int {
        return pendingChunks.count
    }
    
    /// Add chunk to buffer for transfer when connectivity is restored
    func bufferChunk(_ chunk: WatchAudioChunk) {
        // Remove oldest chunk if buffer is full
        if pendingChunks.count >= maxBufferedChunks {
            let removedChunk = pendingChunks.removeFirst()
            print("⌚ Buffer full, dropping chunk \(removedChunk.sequenceNumber)")
        }
        
        pendingChunks.append(chunk)
        onChunkBuffered?(pendingChunks.count)
        print("⌚ Buffered chunk \(chunk.sequenceNumber), buffer size: \(pendingChunks.count)")
    }
    
    /// Attempt to transfer all buffered chunks
    func retryPendingChunks() {
        guard !pendingChunks.isEmpty else { return }
        
        print("⌚ Retrying \(pendingChunks.count) pending chunks")
        
        // Process chunks in order
        let chunksToRetry = pendingChunks
        
        for chunk in chunksToRetry {
            transferChunk(chunk)
        }
    }
    
    /// Mark chunk as successfully transferred
    func markChunkTransferred(_ chunk: WatchAudioChunk) {
        pendingChunks.removeAll { $0.chunkId == chunk.chunkId }
        retryAttempts.removeValue(forKey: chunk.chunkId)
        print("⌚ Chunk \(chunk.sequenceNumber) transferred successfully")
    }
    
    /// Handle chunk transfer failure
    func handleChunkTransferFailure(_ chunk: WatchAudioChunk, error: Error) {
        let currentAttempts = retryAttempts[chunk.chunkId, default: 0]
        
        if currentAttempts < maxRetryAttempts {
            retryAttempts[chunk.chunkId] = currentAttempts + 1
            
            // Add back to buffer if not already there
            if !pendingChunks.contains(where: { $0.chunkId == chunk.chunkId }) {
                bufferChunk(chunk)
            }
            
            print("⌚ Chunk \(chunk.sequenceNumber) transfer failed (attempt \(currentAttempts + 1)/\(maxRetryAttempts))")
        } else {
            // Max retries exceeded, drop chunk
            pendingChunks.removeAll { $0.chunkId == chunk.chunkId }
            retryAttempts.removeValue(forKey: chunk.chunkId)
            
            let transferError = WatchAudioError.transferFailed("Chunk \(chunk.sequenceNumber) dropped after \(maxRetryAttempts) failed attempts")
            onError?(transferError)
            print("⌚ Chunk \(chunk.sequenceNumber) dropped after max retries")
        }
        
        onChunkTransferFailed?(chunk, error)
    }
    
    /// Handle connection loss during recording
    func handleConnectionLost() {
        print("⌚ Connection lost during recording")
        onConnectionLost?()
        
        if isRecording {
            // Continue recording but increase buffering
            increaseBufferCapacity()
            print("⌚ Increased buffer capacity due to connection loss")
        }
    }
    
    /// Handle connection restoration during recording
    func handleConnectionRestored() {
        print("⌚ Connection restored during recording")
        onConnectionRestored?()
        
        // Attempt to transfer all buffered chunks
        retryPendingChunks()
        
        // Restore normal buffer capacity
        restoreNormalBufferCapacity()
    }
    
    /// Increase buffer capacity during connection issues
    private func increaseBufferCapacity() {
        maxBufferedChunks = min(30, maxBufferedChunks * 2) // Up to 30 chunks (~30 seconds)
        print("⌚ Buffer capacity increased to \(maxBufferedChunks) chunks")
    }
    
    /// Restore normal buffer capacity
    private func restoreNormalBufferCapacity() {
        maxBufferedChunks = 10 // Back to normal 10 chunks
        print("⌚ Buffer capacity restored to \(maxBufferedChunks) chunks")
    }
    
    /// Emergency stop recording due to critical issues
    func emergencyStopRecording(reason: String) {
        print("🚨 Emergency stop recording: \(reason)")
        
        if isRecording || isPaused {
            // Save current state
            let currentTime = recordingTime
            
            // Stop recording immediately
            audioRecorder?.stop()
            stopAllTimers()
            
            // Set error state
            isRecording = false
            isPaused = false
            errorMessage = "Recording stopped: \(reason)"
            
            // Try to finalize what we have if there was any recording time
            if currentTime > 1.0 {
                finalizeRecording()
            }
            
            // Notify about the emergency stop
            let error = WatchAudioError.recordingFailed("Emergency stop: \(reason)")
            onError?(error)
            onRecordingStateChanged?(false, false)
            
            // Reset timing
            recordingTime = 0
            pausedDuration = 0
            
            print("🚨 Emergency stop completed. Recording time: \(currentTime) seconds")
        }
    }
    
    /// Check recording health and handle issues
    func performHealthCheck() -> Bool {
        // Check battery level
        updateBatteryLevel()
        if batteryLevel <= 0.05 { // 5% critical
            emergencyStopRecording(reason: "Critical battery level")
            return false
        }
        
        // Check if recording is still active
        if isRecording, let recorder = audioRecorder, !recorder.isRecording {
            print("⚠️ Audio recorder stopped unexpectedly")
            emergencyStopRecording(reason: "Audio recorder failure")
            return false
        }
        
        // Check storage space (basic check)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documentsPath = documentsURL?.path {
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: documentsPath)
                if let freeSpace = attributes[.systemFreeSize] as? Int64 {
                    let freeSpaceMB = freeSpace / (1024 * 1024)
                    if freeSpaceMB < 50 { // Less than 50MB
                        emergencyStopRecording(reason: "Low storage space")
                        return false
                    }
                }
            } catch {
                print("⚠️ Could not check storage space: \(error)")
            }
        }
        
        return true
    }
    
    /// Transfer a single chunk using WatchConnectivityManager with retry logic
    private func transferChunk(_ chunk: WatchAudioChunk) {
        let connectivityManager = WatchConnectivityManager.shared
        
        connectivityManager.transferSingleChunk(chunk) { [weak self] success, error in
            guard let self = self else { return }
            
            if success {
                self.markChunkTransferred(chunk)
                print("⌚ Chunk \(chunk.sequenceNumber) transfer confirmed by phone")
            } else {
                if let error = error {
                    print("⚠️ Chunk \(chunk.sequenceNumber) transfer failed, buffering for retry: \(error.localizedDescription)")
                    self.handleChunkTransferFailure(chunk, error: error)
                } else {
                    let unknownError = WatchAudioError.transferFailed("Unknown transfer error")
                    print("⚠️ Chunk \(chunk.sequenceNumber) transfer failed, buffering for retry: Unknown error")
                    self.handleChunkTransferFailure(chunk, error: unknownError)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupAudioSession() {
        audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession?.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try audioSession?.setActive(true)
            print("⌚ Audio session configured successfully")
        } catch {
            print("⌚ Failed to configure audio session: \(error)")
            let audioError = WatchAudioError.configurationFailed("Failed to configure audio session")
            onError?(audioError)
            errorMessage = audioError.localizedDescription
        }
    }
    
    private func setupAndStartRecording() {
        // Generate unique session ID and recording URL
        currentSessionId = UUID()
        audioChunks.removeAll()
        chunkSequenceNumber = 0
        lastChunkTime = 0 // Reset chunk timing for real-time transfer
        
        // Reset buffer state
        audioBuffer = Data()
        pendingChunks.removeAll()
        retryAttempts.removeAll()
        
        // Reset FileHandle state
        recordingFileHandle?.closeFile()
        recordingFileHandle = nil
        lastReadPosition = 44 // WAV header size
        cachedBytesPerSecond = nil
        
        recordingURL = createRecordingURL()
        guard let url = recordingURL else {
            let error = WatchAudioError.fileSystemError("Failed to create recording file")
            onError?(error)
            errorMessage = error.localizedDescription
            return
        }
        
        // Configure recorder with whisperOptimized settings (matching iOS app)
        let settings = whisperOptimizedAudioSettings
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            
            // Start recording
            guard audioRecorder?.record() == true else {
                throw WatchAudioError.recordingFailed("Failed to start audio recorder")
            }
            
            isRecording = true
            isPaused = false
            recordingTime = 0
            recordingStartTime = Date()
            initialBatteryLevel = batteryLevel
            
            // Start timers
            startRecordingTimer()
            startRetryTimer()
            startChunkTimer() // Start real-time chunking
            
            onRecordingStateChanged?(true, false)
            print("⌚ Recording started successfully")
            
        } catch {
            print("⌚ Failed to start recording: \(error)")
            let audioError = WatchAudioError.recordingFailed(error.localizedDescription)
            onError?(audioError)
            errorMessage = audioError.localizedDescription
        }
    }
    
    private func createRecordingURL() -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let timestamp = Date().timeIntervalSince1970
        let filename = "watchrecording-\(Int(timestamp)).wav"
        return documentsPath?.appendingPathComponent(filename)
    }
    
    private func canStartRecording() -> Bool {
        updateBatteryLevel()
        
        let batteryThreshold: Float = 0.15 // 15% minimum
        let hasEnoughBattery = batteryLevel > batteryThreshold
        
        if !hasEnoughBattery {
            print("⌚ Battery too low for recording: \(Int(batteryLevel * 100))%")
        }
        
        return hasEnoughBattery
    }
    
    /// Audio settings matching iOS app whisperOptimized quality
    private var whisperOptimizedAudioSettings: [String: Any] {
        return [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),  // Use PCM for better chunking
            AVSampleRateKey: WatchAudioFormat.sampleRate,  // 16kHz for voice
            AVNumberOfChannelsKey: WatchAudioFormat.channels,
            AVLinearPCMBitDepthKey: WatchAudioFormat.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }
    
    private func updateBatteryLevel() {
        #if canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        batteryLevel = device.batteryLevel
        #else
        // Fallback for non-watchOS platforms (e.g., when building for iOS simulator)
        batteryLevel = 1.0
        #endif
    }
    
    private func monitorBatteryLevel() {
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.updateBatteryLevel()
                
                if self.isRecording {
                    self.checkBatteryDuringRecording()
                }
            }
        }
    }
    
    private func checkBatteryDuringRecording() {
        let criticalLevel: Float = 0.05 // 5%
        
        if batteryLevel <= criticalLevel {
            print("⌚ Critical battery level during recording, stopping...")
            let error = WatchAudioError.batteryTooLow("Recording stopped due to critical battery level")
            onError?(error)
            stopRecording()
        }
    }
    
    // MARK: - Timer Management
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                guard let startTime = self.recordingStartTime else { return }
                
                if !self.isPaused {
                    self.recordingTime = Date().timeIntervalSince(startTime) - self.pausedDuration
                }
                
                // Perform health check every 10 seconds
                let elapsedSeconds = Int(self.recordingTime)
                if elapsedSeconds > 0 && elapsedSeconds % 10 == 0 {
                    if !self.performHealthCheck() {
                        return // Health check failed, recording was stopped
                    }
                }
                
                // Check maximum recording duration
                if self.recordingTime >= self.maxRecordingDuration {
                    print("⌚ Maximum recording duration reached")
                    self.stopRecording()
                }
            }
        }
    }
    
    private func startRetryTimer() {
        // Retry pending chunks every 3 seconds
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                if !self.pendingChunks.isEmpty {
                    self.retryPendingChunks()
                }
            }
        }
    }
    
    private func startChunkTimer() {
        // Create audio chunks every 1 second during recording
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                if self.isRecording && !self.isPaused {
                    self.createAndTransferRealtimeChunk()
                }
            }
        }
    }
    
    private func stopAllTimers() {
        recordingTimer?.invalidate()
        retryTimer?.invalidate()
        chunkTimer?.invalidate()
        
        recordingTimer = nil
        retryTimer = nil
        chunkTimer = nil
    }
    
    // MARK: - Audio Chunk Management
    
    /// Create and transfer a real-time audio chunk during recording using efficient FileHandle
    private func createAndTransferRealtimeChunk() {
        guard let url = recordingURL,
              let sessionId = currentSessionId,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        do {
            // Initialize FileHandle on first use
            if recordingFileHandle == nil {
                recordingFileHandle = try FileHandle(forReadingFrom: url)
                lastReadPosition = 44 // Skip WAV header
                print("⌚ FileHandle opened for efficient chunk reading")
            }
            
            guard let fileHandle = recordingFileHandle else {
                print("⌚ FileHandle not available, falling back to full file read")
                return createAndTransferRealtimeChunkFallback()
            }
            
            // Get current file size efficiently
            let currentFileSize = fileHandle.seekToEndOfFile()
            
            // Check if we have new data since last read
            guard currentFileSize > lastReadPosition else {
                return // No new data available
            }
            
            // Calculate bytes per second (cached for performance)
            let bytesPerSecond = getBytesPerSecond()
            
            // Calculate how much new data is available
            let availableNewBytes = Int(currentFileSize - lastReadPosition)
            let minChunkSizeBytes = bytesPerSecond / 2 // 0.5 seconds minimum
            
            guard availableNewBytes >= minChunkSizeBytes else {
                return // Not enough new data yet
            }
            
            // Calculate optimal chunk size (aim for 1 second, but don't exceed available data)
            let idealChunkSize = min(bytesPerSecond, availableNewBytes)
            let bytesToRead = min(idealChunkSize, availableNewBytes)
            
            // Seek to last read position and read new data efficiently
            fileHandle.seek(toFileOffset: lastReadPosition)
            let chunkData = fileHandle.readData(ofLength: bytesToRead)
            
            // Update position for next read
            lastReadPosition += UInt64(chunkData.count)
            
            // Calculate chunk duration
            let chunkDuration = Double(chunkData.count) / Double(bytesPerSecond)
            
            // Create the chunk
            let chunk = WatchAudioChunk(
                recordingSessionId: sessionId,
                sequenceNumber: chunkSequenceNumber,
                audioData: chunkData,
                duration: chunkDuration,
                sampleRate: WatchAudioFormat.sampleRate,
                channels: WatchAudioFormat.channels,
                bitDepth: WatchAudioFormat.bitDepth,
                isLastChunk: false // Never last chunk during real-time recording
            )
            
            // Update tracking variables - calculate position based on file handle position
            lastChunkTime = Double(lastReadPosition - 44) / Double(bytesPerSecond) // Subtract WAV header offset
            chunkSequenceNumber += 1
            audioChunks.append(chunk)
            
            // Transfer chunk immediately via callback
            onAudioChunkReady?(chunk)
            
            print("⌚ Created real-time chunk \(chunk.sequenceNumber): \(chunkData.count) bytes, \(String(format: "%.1f", chunkDuration))s")
            
        } catch {
            print("⌚ Error creating real-time chunk with FileHandle: \(error)")
            // Fallback to original method if FileHandle fails
            createAndTransferRealtimeChunkFallback()
        }
    }
    
    /// Fallback method using original file reading approach
    private func createAndTransferRealtimeChunkFallback() {
        guard let url = recordingURL,
              let sessionId = currentSessionId else {
            return
        }
        
        do {
            // Read current recording file (original method)
            let fileData = try Data(contentsOf: url)
            
            // Skip WAV header (44 bytes)
            let headerSize = 44
            guard fileData.count > headerSize else { return }
            
            let audioData = fileData.subdata(in: headerSize..<fileData.count)
            let currentFileSize = audioData.count
            
            // Calculate how much new audio data we have since last chunk
            let bytesPerSecond = getBytesPerSecond()
            let lastChunkEndByte = Int(lastChunkTime * Double(bytesPerSecond))
            
            // Only create chunk if we have enough new data (at least 0.5 seconds)
            let minChunkSizeBytes = bytesPerSecond / 2 // 0.5 seconds minimum
            let newDataSize = currentFileSize - lastChunkEndByte
            
            guard newDataSize >= minChunkSizeBytes else {
                return // Not enough new data yet
            }
            
            // Calculate chunk size (aim for 1 second, but don't exceed available data)
            let idealChunkSize = min(bytesPerSecond, newDataSize)
            let chunkEndByte = min(lastChunkEndByte + idealChunkSize, currentFileSize)
            
            let chunkData = audioData.subdata(in: lastChunkEndByte..<chunkEndByte)
            let chunkDuration = Double(chunkData.count) / Double(bytesPerSecond)
            
            // Create the chunk
            let chunk = WatchAudioChunk(
                recordingSessionId: sessionId,
                sequenceNumber: chunkSequenceNumber,
                audioData: chunkData,
                duration: chunkDuration,
                sampleRate: WatchAudioFormat.sampleRate,
                channels: WatchAudioFormat.channels,
                bitDepth: WatchAudioFormat.bitDepth,
                isLastChunk: false
            )
            
            // Update tracking variables
            lastChunkTime = Double(chunkEndByte) / Double(bytesPerSecond)
            chunkSequenceNumber += 1
            audioChunks.append(chunk)
            
            // Transfer chunk immediately via callback
            onAudioChunkReady?(chunk)
            
            print("⌚ Created fallback chunk \(chunk.sequenceNumber): \(chunkData.count) bytes, \(String(format: "%.1f", chunkDuration))s")
            
        } catch {
            print("⌚ Error in fallback chunk creation: \(error)")
        }
    }
    
    /// Get bytes per second with caching for performance
    private func getBytesPerSecond() -> Int {
        if let cached = cachedBytesPerSecond {
            return cached
        }
        
        let calculated = Int(WatchAudioFormat.sampleRate * Double(WatchAudioFormat.channels) * (Double(WatchAudioFormat.bitDepth) / 8.0))
        cachedBytesPerSecond = calculated
        return calculated
    }
    
    private func finalizeRecording() {
        // Close FileHandle when recording finishes
        recordingFileHandle?.closeFile()
        recordingFileHandle = nil
        
        guard let url = recordingURL,
              let sessionId = currentSessionId,
              FileManager.default.fileExists(atPath: url.path) else {
            print("⌚ Recording file not found for finalization")
            onRecordingCompleted?(audioChunks)
            return
        }
        
        do {
            // Read the complete recorded audio file
            let completeAudioData = try Data(contentsOf: url)
            
            // Skip WAV header (44 bytes)
            let headerSize = 44
            let audioDataStart = min(headerSize, completeAudioData.count)
            let pureAudioData = completeAudioData.subdata(in: audioDataStart..<completeAudioData.count)
            
            print("⌚ Finalizing recording: \(completeAudioData.count) total bytes, \(pureAudioData.count) audio bytes")
            
            // Create final chunk for any remaining audio data that wasn't sent during real-time transfer
            let bytesPerSecond = getBytesPerSecond()
            let lastChunkEndByte = Int(lastChunkTime * Double(bytesPerSecond))
            
            if lastChunkEndByte < pureAudioData.count {
                // There's remaining audio data to send as final chunk
                let finalChunkData = pureAudioData.subdata(in: lastChunkEndByte..<pureAudioData.count)
                let finalChunkDuration = Double(finalChunkData.count) / Double(bytesPerSecond)
                
                let finalChunk = WatchAudioChunk(
                    recordingSessionId: sessionId,
                    sequenceNumber: chunkSequenceNumber,
                    audioData: finalChunkData,
                    duration: finalChunkDuration,
                    sampleRate: WatchAudioFormat.sampleRate,
                    channels: WatchAudioFormat.channels,
                    bitDepth: WatchAudioFormat.bitDepth,
                    isLastChunk: true // This is the final chunk
                )
                
                audioChunks.append(finalChunk)
                
                // Send final chunk immediately
                onAudioChunkReady?(finalChunk)
                
                print("⌚ Created final chunk \(finalChunk.sequenceNumber): \(finalChunkData.count) bytes, \(String(format: "%.1f", finalChunkDuration))s")
            } else if !audioChunks.isEmpty {
                // Mark the last chunk we sent as the final chunk
                if let lastChunk = audioChunks.last {
                    audioChunks.removeLast()
                    
                    // Create updated final chunk
                    let updatedFinalChunk = WatchAudioChunk(
                        recordingSessionId: sessionId,
                        sequenceNumber: lastChunk.sequenceNumber,
                        audioData: lastChunk.audioData,
                        duration: lastChunk.duration,
                        sampleRate: lastChunk.sampleRate,
                        channels: lastChunk.channels,
                        bitDepth: lastChunk.bitDepth,
                        isLastChunk: true
                    )
                    
                    audioChunks.append(updatedFinalChunk)
                    onAudioChunkReady?(updatedFinalChunk)
                    
                    print("⌚ Marked chunk \(updatedFinalChunk.sequenceNumber) as final chunk")
                }
            }
            
            // Notify completion with all chunks
            onRecordingCompleted?(audioChunks)
            
        } catch {
            print("⌚ Failed to finalize recording: \(error)")
            let audioError = WatchAudioError.fileSystemError("Failed to read recording file: \(error.localizedDescription)")
            onError?(audioError)
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension WatchAudioManager: AVAudioRecorderDelegate {
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            print("⌚ Audio recorder finished, success: \(flag)")
            
            // Clean up state first
            isRecording = false
            isPaused = false
            stopAllTimers()
            
            if flag {
                // Successfully recorded, now finalize the chunks
                finalizeRecording()
            } else {
                print("⌚ Audio recorder finished with error")
                let error = WatchAudioError.recordingFailed("Recording completed unsuccessfully")
                onError?(error)
                errorMessage = error.localizedDescription
            }
            
            // Reset timing for next recording
            recordingTime = 0
            pausedDuration = 0
            
            onRecordingStateChanged?(false, false)
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            print("⌚ Audio recorder encode error: \(error?.localizedDescription ?? "Unknown error")")
            
            let audioError = WatchAudioError.recordingFailed(error?.localizedDescription ?? "Encoding error occurred")
            onError?(audioError)
            errorMessage = audioError.localizedDescription
            
            stopRecording()
        }
    }
}

// MARK: - Supporting Types

/// Watch-specific audio errors
enum WatchAudioError: LocalizedError {
    case permissionDenied(String)
    case batteryTooLow(String)
    case configurationFailed(String)
    case recordingFailed(String)
    case fileSystemError(String)
    case transferFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let message):
            return "Permission Denied: \(message)"
        case .batteryTooLow(let message):
            return "Battery Too Low: \(message)"
        case .configurationFailed(let message):
            return "Configuration Failed: \(message)"
        case .recordingFailed(let message):
            return "Recording Failed: \(message)"
        case .fileSystemError(let message):
            return "File System Error: \(message)"
        case .transferFailed(let message):
            return "Transfer Failed: \(message)"
        }
    }
}