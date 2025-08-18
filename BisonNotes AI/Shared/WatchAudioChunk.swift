//
//  WatchAudioChunk.swift
//  BisonNotes AI
//
//  Created by Claude on 8/17/25.
//

import Foundation
import AVFoundation

/// Represents a chunk of audio data transferred from watch to phone
struct WatchAudioChunk: Codable {
    let chunkId: UUID
    let recordingSessionId: UUID
    let sequenceNumber: Int
    let audioData: Data
    let timestamp: Date
    let duration: TimeInterval
    let sampleRate: Double
    let channels: Int
    let bitDepth: Int
    let isLastChunk: Bool
    
    init(recordingSessionId: UUID, sequenceNumber: Int, audioData: Data, duration: TimeInterval, sampleRate: Double = 16000, channels: Int = 1, bitDepth: Int = 16, isLastChunk: Bool = false) {
        self.chunkId = UUID()
        self.recordingSessionId = recordingSessionId
        self.sequenceNumber = sequenceNumber
        self.audioData = audioData
        self.timestamp = Date()
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isLastChunk = isLastChunk
    }
    
    /// Size of the audio data in bytes
    var sizeInBytes: Int {
        return audioData.count
    }
    
    /// Size of the audio data in KB
    var sizeInKB: Double {
        return Double(sizeInBytes) / 1024.0
    }
    
    /// Convert to dictionary for WatchConnectivity transfer
    func toDictionary() -> [String: Any] {
        return [
            "chunkId": chunkId.uuidString,
            "recordingSessionId": recordingSessionId.uuidString,
            "sequenceNumber": sequenceNumber,
            "audioData": audioData,
            "timestamp": timestamp.timeIntervalSince1970,
            "duration": duration,
            "sampleRate": sampleRate,
            "channels": channels,
            "bitDepth": bitDepth,
            "isLastChunk": isLastChunk
        ]
    }
    
    /// Create from dictionary received via WatchConnectivity
    static func fromDictionary(_ dict: [String: Any]) -> WatchAudioChunk? {
        guard let chunkIdString = dict["chunkId"] as? String,
              let chunkId = UUID(uuidString: chunkIdString),
              let recordingSessionIdString = dict["recordingSessionId"] as? String,
              let recordingSessionId = UUID(uuidString: recordingSessionIdString),
              let sequenceNumber = dict["sequenceNumber"] as? Int,
              let audioData = dict["audioData"] as? Data,
              let timestampInterval = dict["timestamp"] as? TimeInterval,
              let duration = dict["duration"] as? TimeInterval,
              let sampleRate = dict["sampleRate"] as? Double,
              let channels = dict["channels"] as? Int,
              let bitDepth = dict["bitDepth"] as? Int,
              let isLastChunk = dict["isLastChunk"] as? Bool else {
            return nil
        }
        
        var chunk = WatchAudioChunk(
            recordingSessionId: recordingSessionId,
            sequenceNumber: sequenceNumber,
            audioData: audioData,
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            isLastChunk: isLastChunk
        )
        
        // Override the auto-generated values with the received ones
        chunk = WatchAudioChunk(
            chunkId: chunkId,
            recordingSessionId: recordingSessionId,
            sequenceNumber: sequenceNumber,
            audioData: audioData,
            timestamp: Date(timeIntervalSince1970: timestampInterval),
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            isLastChunk: isLastChunk
        )
        
        return chunk
    }
    
    private init(chunkId: UUID, recordingSessionId: UUID, sequenceNumber: Int, audioData: Data, timestamp: Date, duration: TimeInterval, sampleRate: Double, channels: Int, bitDepth: Int, isLastChunk: Bool) {
        self.chunkId = chunkId
        self.recordingSessionId = recordingSessionId
        self.sequenceNumber = sequenceNumber
        self.audioData = audioData
        self.timestamp = timestamp
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isLastChunk = isLastChunk
    }
}

/// Manages collection and transfer of audio chunks from watch
class WatchAudioChunkManager: ObservableObject {
    @Published var chunksInTransfer: [WatchAudioChunk] = []
    @Published var transferProgress: Double = 0.0
    @Published var totalChunksExpected: Int = 0
    @Published var chunksReceived: Int = 0
    
    var currentRecordingSession: UUID?
    private var receivedChunks: [Int: WatchAudioChunk] = [:]
    
    /// Start a new recording session
    func startRecordingSession() -> UUID {
        let sessionId = UUID()
        currentRecordingSession = sessionId
        receivedChunks.removeAll()
        chunksReceived = 0
        totalChunksExpected = 0
        transferProgress = 0.0
        
        return sessionId
    }
    
    /// Add a received chunk
    func addReceivedChunk(_ chunk: WatchAudioChunk) {
        receivedChunks[chunk.sequenceNumber] = chunk
        chunksReceived = receivedChunks.count
        
        // Update progress
        if totalChunksExpected > 0 {
            transferProgress = Double(chunksReceived) / Double(totalChunksExpected)
        }
        
        // If this is the last chunk, update total expected
        if chunk.isLastChunk {
            totalChunksExpected = chunk.sequenceNumber + 1
            transferProgress = Double(chunksReceived) / Double(totalChunksExpected)
        }
    }
    
    /// Get all chunks in order for the current session
    func getAllChunksInOrder() -> [WatchAudioChunk]? {
        guard let sessionId = currentRecordingSession else { return nil }
        
        // Filter chunks for current session and sort by sequence number
        let sessionChunks = receivedChunks.values
            .filter { $0.recordingSessionId == sessionId }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        
        return sessionChunks.isEmpty ? nil : sessionChunks
    }
    
    /// Get all chunks in order, filling gaps with silence for missing chunks
    func getAllChunksWithGapFilling() -> [WatchAudioChunk]? {
        guard let sessionId = currentRecordingSession else { return nil }
        guard totalChunksExpected > 0 else { return nil }
        
        // Filter chunks for current session
        let sessionChunks = receivedChunks.values.filter { $0.recordingSessionId == sessionId }
        guard !sessionChunks.isEmpty else { return nil }
        
        var orderedChunks: [WatchAudioChunk] = []
        
        // Fill in chunks, creating silent chunks for missing ones
        for i in 0..<totalChunksExpected {
            if let chunk = receivedChunks[i] {
                orderedChunks.append(chunk)
            } else {
                // Create a silent chunk for the missing sequence
                print("⚠️ Creating silent chunk for missing sequence \(i)")
                let silentChunk = createSilentChunk(sequenceNumber: i, sessionId: sessionId)
                orderedChunks.append(silentChunk)
            }
        }
        
        return orderedChunks
    }
    
    /// Create a silent audio chunk for missing sequences
    private func createSilentChunk(sequenceNumber: Int, sessionId: UUID) -> WatchAudioChunk {
        let silentDataSize = Int(WatchAudioFormat.expectedChunkDataSize(durationSeconds: 1.0))
        let silentData = Data(repeating: 0, count: silentDataSize)
        
        return WatchAudioChunk(
            recordingSessionId: sessionId,
            sequenceNumber: sequenceNumber,
            audioData: silentData,
            duration: 1.0,
            sampleRate: WatchAudioFormat.sampleRate,
            channels: WatchAudioFormat.channels,
            bitDepth: WatchAudioFormat.bitDepth,
            isLastChunk: false
        )
    }
    
    /// Combine all audio chunks into a single Data object
    func combineAudioChunks() -> Data? {
        // First try to get complete chunks without gaps
        if let completeChunks = getAllChunksInOrder(),
           completeChunks.count == totalChunksExpected {
            print("✅ Combining \(completeChunks.count) complete audio chunks")
            var combinedData = Data()
            for chunk in completeChunks {
                combinedData.append(chunk.audioData)
            }
            return combinedData
        }
        
        // If we have missing chunks, use gap filling
        if let chunksWithGaps = getAllChunksWithGapFilling() {
            print("⚠️ Combining \(chunksWithGaps.count) audio chunks with \(getMissingChunks().count) gaps filled with silence")
            var combinedData = Data()
            for chunk in chunksWithGaps {
                combinedData.append(chunk.audioData)
            }
            return combinedData
        }
        
        return nil
    }
    
    /// Check if all chunks have been received for the current session
    var isTransferComplete: Bool {
        guard totalChunksExpected > 0 else { return false }
        return chunksReceived >= totalChunksExpected
    }
    
    /// Check if a chunk with given sequence number exists
    func hasChunk(sequenceNumber: Int) -> Bool {
        return receivedChunks[sequenceNumber] != nil
    }
    
    /// Get missing chunk sequence numbers
    func getMissingChunks() -> [Int] {
        guard totalChunksExpected > 0 else { return [] }
        
        var missing: [Int] = []
        for i in 0..<totalChunksExpected {
            if receivedChunks[i] == nil {
                missing.append(i)
            }
        }
        return missing
    }
    
    /// Reset for next recording session
    func reset() {
        currentRecordingSession = nil
        receivedChunks.removeAll()
        chunksReceived = 0
        totalChunksExpected = 0
        transferProgress = 0.0
        chunksInTransfer.removeAll()
    }
}

/// Audio format configuration for watch recording
struct WatchAudioFormat {
    static let sampleRate: Double = 16000  // 16kHz for voice, matching Whisper optimal
    static let channels: Int = 1           // Mono
    static let bitDepth: Int = 16          // 16-bit
    static let chunkDurationSeconds: TimeInterval = 1.0  // 1-second chunks (for WatchConnectivity size limits)
    
    /// Calculate expected data size for a chunk
    static func expectedChunkDataSize(durationSeconds: TimeInterval) -> Int {
        // bytes = sampleRate * channels * (bitDepth/8) * duration
        return Int(sampleRate * Double(channels) * (Double(bitDepth) / 8.0) * durationSeconds)
    }
    
    /// Audio recording settings for AVAudioRecorder on watch
    static var audioRecorderSettings: [String: Any] {
        return [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
    }
}