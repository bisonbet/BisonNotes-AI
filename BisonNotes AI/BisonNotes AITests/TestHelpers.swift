//
//  TestHelpers.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import Foundation
import AVFoundation
@testable import BisonNotes_AI

// MARK: - Mock Data Generators

struct TestHelpers {
    
    /// Creates a mock audio file info for testing
    static func createMockAudioFileInfo(
        duration: TimeInterval = 60.0,
        fileSize: Int64 = 1024 * 1024,
        format: String = "m4a",
        sampleRate: Double = 44100,
        channels: Int = 2
    ) -> AudioFileInfo {
        return AudioFileInfo(
            duration: duration,
            fileSize: fileSize,
            format: format,
            sampleRate: sampleRate,
            channels: channels
        )
    }
    
    /// Creates a mock audio chunk for testing
    static func createMockAudioChunk(
        sequenceNumber: Int = 0,
        startTime: TimeInterval = 0.0,
        endTime: TimeInterval = 60.0,
        fileSize: Int64 = 1024 * 1024
    ) -> AudioChunk {
        let originalURL = URL(fileURLWithPath: "/test/original.m4a")
        let chunkURL = URL(fileURLWithPath: "/test/chunk_\(sequenceNumber).m4a")
        
        return AudioChunk(
            originalURL: originalURL,
            chunkURL: chunkURL,
            sequenceNumber: sequenceNumber,
            startTime: startTime,
            endTime: endTime,
            fileSize: fileSize
        )
    }
    
    /// Creates a mock transcript chunk for testing
    static func createMockTranscriptChunk(
        sequenceNumber: Int = 0,
        transcript: String = "Test transcript",
        startTime: TimeInterval = 0.0,
        endTime: TimeInterval = 60.0,
        processingTime: TimeInterval = 3.0
    ) -> TranscriptChunk {
        let segments = [
            TranscriptSegment(
                speaker: "Speaker",
                text: transcript,
                startTime: startTime,
                endTime: endTime
            )
        ]
        
        return TranscriptChunk(
            chunkId: UUID(),
            sequenceNumber: sequenceNumber,
            transcript: transcript,
            segments: segments,
            startTime: startTime,
            endTime: endTime,
            processingTime: processingTime
        )
    }
    
    /// Creates a mock processing job for testing
    static func createMockProcessingJob(
        type: JobType = .transcription(engine: .openAI),
        recordingName: String = "Test Recording"
    ) -> ProcessingJob {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        return ProcessingJob(
            type: type,
            recordingURL: testURL,
            recordingName: recordingName
        )
    }
    
    /// Creates a mock enhanced summary data for testing
    static func createMockEnhancedSummaryData(
        summary: String = "Test summary",
        tasks: [String] = ["Task 1", "Task 2"],
        reminders: [String] = ["Reminder 1"],
        titles: [String] = ["Test Title"]
    ) -> EnhancedSummaryData {
        return EnhancedSummaryData(
            id: UUID(),
            recordingURL: URL(fileURLWithPath: "/test/recording.m4a"),
            recordingName: "Test Recording",
            recordingDate: Date(),
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: .meeting,
            aiMethod: "GPT-4",
            generatedAt: Date(),
            version: "1.0",
            wordCount: 5,
            originalLength: 60.0,
            compressionRatio: 0.1,
            confidence: 0.95,
            processingTime: 5.0,
            deviceIdentifier: "test-device",
            lastModified: Date()
        )
    }
    
    /// Creates a mock file relationships for testing
    static func createMockFileRelationships(
        hasRecording: Bool = true,
        transcriptExists: Bool = true,
        summaryExists: Bool = true,
        iCloudSynced: Bool = false
    ) -> FileRelationships {
        let recordingURL = hasRecording ? URL(fileURLWithPath: "/test/recording.m4a") : nil
        
        return FileRelationships(
            recordingURL: recordingURL,
            recordingName: "Test Recording",
            recordingDate: Date(),
            transcriptExists: transcriptExists,
            summaryExists: summaryExists,
            iCloudSynced: iCloudSynced
        )
    }
    
    /// Creates a mock chunking result for testing
    static func createMockChunkingResult(
        chunkCount: Int = 2,
        totalDuration: TimeInterval = 120.0,
        totalSize: Int64 = 2 * 1024 * 1024,
        chunkingTime: TimeInterval = 5.0
    ) -> ChunkingResult {
        var chunks: [AudioChunk] = []
        
        for i in 0..<chunkCount {
            let chunk = createMockAudioChunk(
                sequenceNumber: i,
                startTime: TimeInterval(i * 60),
                endTime: TimeInterval((i + 1) * 60),
                fileSize: totalSize / Int64(chunkCount)
            )
            chunks.append(chunk)
        }
        
        return ChunkingResult(
            chunks: chunks,
            totalDuration: totalDuration,
            totalSize: totalSize,
            chunkingTime: chunkingTime
        )
    }
}

// MARK: - Test Utilities

extension TestHelpers {
    
    /// Measures execution time of a closure
    static func measureExecutionTime<T>(_ operation: () throws -> T) rethrows -> (result: T, time: TimeInterval) {
        let startTime = Date()
        let result = try operation()
        let endTime = Date()
        return (result, endTime.timeIntervalSince(startTime))
    }
    
    /// Creates a temporary directory for testing
    static func createTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioJournalTests")
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        return tempDir
    }
    
    /// Cleans up temporary directory
    static func cleanupTemporaryDirectory(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    /// Creates a mock audio file for testing
    static func createMockAudioFile(at url: URL, duration: TimeInterval = 60.0) throws {
        // Create a simple audio file structure for testing
        let data = Data(repeating: 0, count: 1024) // 1KB of zeros
        try data.write(to: url)
    }
    
    /// Validates that a file exists and has expected size
    static func validateFile(at url: URL, expectedSize: Int64? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        
        if let expectedSize = expectedSize {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = attributes?[.size] as? Int64 ?? 0
            return actualSize == expectedSize
        }
        
        return true
    }
}

// MARK: - Mock Services

class MockAudioSessionManager: EnhancedAudioSessionManager {
    var mockConfigurationSuccess = true
    var mockInterruptionHandled = false
    
    override func configureMixedAudioSession() async throws {
        if !mockConfigurationSuccess {
            throw AudioProcessingError.audioSessionConfigurationFailed("Mock failure")
        }
        
        await MainActor.run {
            self.isConfigured = true
            self.isMixedAudioEnabled = true
            self.currentConfiguration = .mixedAudioRecording
        }
    }
    
    override func handleAudioInterruption(_ notification: Notification) {
        mockInterruptionHandled = true
        super.handleAudioInterruption(notification)
    }
}

class MockChunkingService: AudioFileChunkingService {
    var mockChunkingResult: ChunkingResult?
    var mockShouldChunk = false
    var mockError: Error?
    
    override func shouldChunkFile(_ url: URL, for engine: TranscriptionEngine) async throws -> Bool {
        if let error = mockError {
            throw error
        }
        return mockShouldChunk
    }
    
    override func chunkAudioFile(_ url: URL, for engine: TranscriptionEngine) async throws -> ChunkingResult {
        if let error = mockError {
            throw error
        }
        
        if let result = mockChunkingResult {
            return result
        }
        
        // Return default result
        return TestHelpers.createMockChunkingResult()
    }
}

class MockBackgroundProcessingManager: BackgroundProcessingManager {
    var mockJobExecutionSuccess = true
    var mockJobError: Error?
    
    override func startTranscription(_ job: ProcessingJob) async throws {
        if !mockJobExecutionSuccess {
            throw mockJobError ?? AudioProcessingError.backgroundProcessingFailed("Mock failure")
        }
        
        await MainActor.run {
            self.activeJobs.append(job.withStatus(.processing))
        }
        
        // Simulate processing time
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        await MainActor.run {
            if let index = self.activeJobs.firstIndex(where: { $0.id == job.id }) {
                self.activeJobs[index] = self.activeJobs[index].withStatus(.completed)
            }
        }
    }
}

class MockiCloudStorageManager: iCloudStorageManager {
    var mockSyncSuccess = true
    var mockSyncError: Error?
    var mockIsEnabled = false
    
    override var isEnabled: Bool {
        get { mockIsEnabled }
        set { mockIsEnabled = newValue }
    }
    
    override func enableiCloudSync() async throws {
        if !mockSyncSuccess {
            throw mockSyncError ?? AudioProcessingError.iCloudSyncFailed("Mock failure")
        }
        
        await MainActor.run {
            self.isEnabled = true
            self.syncStatus = .completed
        }
    }
    
    override func disableiCloudSync() async throws {
        await MainActor.run {
            self.isEnabled = false
            self.syncStatus = .idle
        }
    }
}

// MARK: - Test Assertions

extension TestHelpers {
    
    /// Asserts that a job has the expected status
    static func assertJobStatus(_ job: ProcessingJob, expected: ProcessingStatus) {
        assert(job.status == expected, "Expected job status \(expected), but got \(job.status)")
    }
    
    /// Asserts that a job has the expected progress
    static func assertJobProgress(_ job: ProcessingJob, expected: Double, tolerance: Double = 0.01) {
        assert(abs(job.progress - expected) < tolerance, "Expected job progress \(expected), but got \(job.progress)")
    }
    
    /// Asserts that a file exists
    static func assertFileExists(at url: URL) {
        assert(FileManager.default.fileExists(atPath: url.path), "Expected file to exist at \(url.path)")
    }
    
    /// Asserts that a file does not exist
    static func assertFileDoesNotExist(at url: URL) {
        assert(!FileManager.default.fileExists(atPath: url.path), "Expected file to not exist at \(url.path)")
    }
    
    /// Asserts that a directory exists
    static func assertDirectoryExists(at url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        assert(exists && isDirectory.boolValue, "Expected directory to exist at \(url.path)")
    }
}

// MARK: - Performance Testing

extension TestHelpers {
    
    /// Runs a performance test with multiple iterations
    static func runPerformanceTest<T>(
        iterations: Int = 100,
        operation: () throws -> T
    ) rethrows -> (result: T, averageTime: TimeInterval) {
        var totalTime: TimeInterval = 0
        
        for _ in 0..<iterations {
            let (_, time) = try measureExecutionTime(operation)
            totalTime += time
        }
        
        let averageTime = totalTime / Double(iterations)
        let result = try operation()
        
        return (result, averageTime)
    }
    
    /// Asserts that an operation completes within a time limit
    static func assertOperationCompletesWithin(
        _ timeLimit: TimeInterval,
        operation: () throws -> Void
    ) rethrows {
        let (_, time) = try measureExecutionTime(operation)
        assert(time < timeLimit, "Operation took \(time)s, expected less than \(timeLimit)s")
    }
}

// MARK: - Network Testing

extension TestHelpers {
    
    /// Simulates network availability changes
    static func simulateNetworkStatus(_ status: NetworkStatus) {
        // In a real implementation, this would trigger network status change notifications
        // For testing, we just verify the status enum behavior
        assert(status.canSync == (status == .available), "Network status sync capability mismatch")
    }
    
    /// Simulates network failure
    static func simulateNetworkFailure() -> NetworkStatus {
        return .unavailable
    }
    
    /// Simulates network recovery
    static func simulateNetworkRecovery() -> NetworkStatus {
        return .available
    }
} 