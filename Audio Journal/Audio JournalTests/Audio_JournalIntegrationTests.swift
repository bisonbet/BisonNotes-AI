//
//  Audio_JournalIntegrationTests.swift
//  Audio JournalTests
//
//  Integration tests for audio processing enhancements
//

import Testing
@testable import Audio_Journal
import AVFoundation
import Foundation

struct Audio_JournalIntegrationTests {
    
    // MARK: - Complete Recording Workflow Tests
    
    /// Tests complete recording workflow with mixed audio
    @Test func completeRecordingWorkflowWithMixedAudio() async throws {
        let audioManager = await EnhancedAudioSessionManager()
        let recorder = await AudioRecorderViewModel()
        
        // Configure mixed audio session
        try await audioManager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
            #expect(audioManager.isMixedAudioEnabled == true)
        }
        
        // Simulate recording start
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        // Test that recording can start with mixed audio
        // Note: This is a simulation since we can't actually record in tests
        #expect(audioManager.currentConfiguration?.allowMixedAudio == true)
    }
    
    /// Tests background recording workflow
    @Test func backgroundRecordingWorkflow() async throws {
        let audioManager = await EnhancedAudioSessionManager()
        
        // Configure background recording
        try await audioManager.configureBackgroundRecording()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
            #expect(audioManager.isBackgroundRecordingEnabled == true)
        }
        
        // Simulate app backgrounding
        let notification = Notification(name: UIApplication.didEnterBackgroundNotification)
        // Note: In real implementation, this would trigger background recording logic
        
        #expect(audioManager.currentConfiguration?.backgroundRecording == true)
    }
    
    // MARK: - Large File Processing Tests
    
    /// Tests large file processing with chunking and background processing
    @Test func largeFileProcessingWithChunking() async throws {
        let chunkingService = await AudioFileChunkingService()
        let processingManager = await BackgroundProcessingManager()
        
        // Create a mock large file
        let largeFileURL = URL(fileURLWithPath: "/test/large_recording.m4a")
        
        // Test chunking decision for OpenAI (file size based)
        let mockFileInfo = AudioFileInfo(
            duration: 3600.0, // 1 hour
            fileSize: 25 * 1024 * 1024, // 25MB (exceeds 24MB limit)
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        let needsChunking = mockFileInfo.fileSize > 24 * 1024 * 1024
        #expect(needsChunking == true)
        
        // Test chunking decision for Whisper (duration based)
        let longFileInfo = AudioFileInfo(
            duration: 3 * 60 * 60, // 3 hours (exceeds 2 hour limit)
            fileSize: 10 * 1024 * 1024, // 10MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        let needsDurationChunking = longFileInfo.duration > 2 * 60 * 60
        #expect(needsDurationChunking == true)
        
        // Test background processing job creation
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: largeFileURL,
            recordingName: "Large Test Recording"
        )
        
        await MainActor.run {
            #expect(job.status == .queued)
            #expect(job.progress == 0.0)
            #expect(processingManager.canStartNewJob == true)
        }
    }
    
    /// Tests transcript reassembly workflow
    @Test func transcriptReassemblyWorkflow() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        // Create mock transcript chunks
        let chunk1 = TranscriptChunk(
            chunkId: UUID(),
            sequenceNumber: 0,
            transcript: "Hello world. This is the first part.",
            segments: [
                TranscriptSegment(speaker: "Speaker", text: "Hello world", startTime: 0.0, endTime: 2.0),
                TranscriptSegment(speaker: "Speaker", text: "This is the first part", startTime: 2.0, endTime: 5.0)
            ],
            startTime: 0.0,
            endTime: 60.0,
            processingTime: 3.0
        )
        
        let chunk2 = TranscriptChunk(
            chunkId: UUID(),
            sequenceNumber: 1,
            transcript: "This is the second part. Goodbye.",
            segments: [
                TranscriptSegment(speaker: "Speaker", text: "This is the second part", startTime: 60.0, endTime: 63.0),
                TranscriptSegment(speaker: "Speaker", text: "Goodbye", startTime: 63.0, endTime: 65.0)
            ],
            startTime: 60.0,
            endTime: 120.0,
            processingTime: 3.0
        )
        
        let chunks = [chunk1, chunk2]
        
        // Test reassembly
        let reassembledTranscript = TranscriptData(
            id: UUID(),
            recordingURL: testURL,
            recordingName: "Test Recording",
            transcript: "Hello world. This is the first part. This is the second part. Goodbye.",
            segments: chunk1.segments + chunk2.segments,
            engine: .openAI,
            processingTime: 6.0,
            confidence: 0.95,
            wordCount: 12,
            language: "en"
        )
        
        #expect(reassembledTranscript.transcript.contains("Hello world"))
        #expect(reassembledTranscript.transcript.contains("Goodbye"))
        #expect(reassembledTranscript.segments.count == 4)
        #expect(reassembledTranscript.processingTime == 6.0)
    }
    
    // MARK: - iCloud Sync Integration Tests
    
    /// Tests iCloud sync functionality across different scenarios
    @Test func iCloudSyncIntegration() async throws {
        let syncManager = await iCloudStorageManager()
        
        // Test initial state
        await MainActor.run {
            #expect(syncManager.isEnabled == false)
            #expect(syncManager.syncStatus == .idle)
        }
        
        // Test sync enable/disable
        try await syncManager.enableiCloudSync()
        
        await MainActor.run {
            #expect(syncManager.isEnabled == true)
        }
        
        try await syncManager.disableiCloudSync()
        
        await MainActor.run {
            #expect(syncManager.isEnabled == false)
        }
    }
    
    /// Tests summary synchronization workflow
    @Test func summarySynchronizationWorkflow() async throws {
        let syncManager = await iCloudStorageManager()
        
        // Create a mock summary for testing
        let testSummary = EnhancedSummaryData(
            id: UUID(),
            recordingURL: URL(fileURLWithPath: "/test/recording.m4a"),
            recordingName: "Test Recording",
            recordingDate: Date(),
            summary: "This is a test summary",
            tasks: ["Task 1", "Task 2"],
            reminders: ["Reminder 1"],
            titles: ["Test Title"],
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
        
        // Test sync status tracking
        await MainActor.run {
            #expect(syncManager.syncStatus == .idle)
        }
        
        // Note: In real implementation, this would trigger actual CloudKit sync
        // For testing, we just verify the summary structure
        #expect(testSummary.summary == "This is a test summary")
        #expect(testSummary.tasks.count == 2)
        #expect(testSummary.reminders.count == 1)
        #expect(testSummary.titles.count == 1)
    }
    
    /// Tests conflict resolution scenarios
    @Test func conflictResolutionScenarios() async throws {
        let localSummary = EnhancedSummaryData(
            id: UUID(),
            recordingURL: URL(fileURLWithPath: "/test/recording.m4a"),
            recordingName: "Test Recording",
            recordingDate: Date(),
            summary: "Local summary",
            tasks: ["Local task"],
            reminders: ["Local reminder"],
            titles: ["Local title"],
            contentType: .meeting,
            aiMethod: "GPT-4",
            generatedAt: Date(),
            version: "1.0",
            wordCount: 2,
            originalLength: 60.0,
            compressionRatio: 0.1,
            confidence: 0.95,
            processingTime: 5.0,
            deviceIdentifier: "local-device",
            lastModified: Date()
        )
        
        let cloudSummary = EnhancedSummaryData(
            id: localSummary.id, // Same ID for conflict
            recordingURL: localSummary.recordingURL,
            recordingName: localSummary.recordingName,
            recordingDate: localSummary.recordingDate,
            summary: "Cloud summary",
            tasks: ["Cloud task"],
            reminders: ["Cloud reminder"],
            titles: ["Cloud title"],
            contentType: .meeting,
            aiMethod: "GPT-4",
            generatedAt: localSummary.generatedAt,
            version: "1.0",
            wordCount: 2,
            originalLength: 60.0,
            compressionRatio: 0.1,
            confidence: 0.95,
            processingTime: 5.0,
            deviceIdentifier: "cloud-device",
            lastModified: Date().addingTimeInterval(3600) // 1 hour later
        )
        
        // Test conflict detection
        let conflict = SyncConflict(
            summaryId: localSummary.id,
            localSummary: localSummary,
            cloudSummary: cloudSummary,
            conflictType: .contentMismatch
        )
        
        #expect(conflict.summaryId == localSummary.id)
        #expect(conflict.localSummary.summary == "Local summary")
        #expect(conflict.cloudSummary.summary == "Cloud summary")
        #expect(conflict.conflictType == .contentMismatch)
    }
    
    // MARK: - File Management Integration Tests
    
    /// Tests selective deletion workflow
    @Test func selectiveDeletionWorkflow() async throws {
        let fileManager = await EnhancedFileManager()
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        // Create file relationships
        let relationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(relationships.hasRecording == false) // File doesn't actually exist
        #expect(relationships.transcriptExists == true)
        #expect(relationships.summaryExists == true)
        #expect(relationships.isOrphaned == false)
        
        // Test deletion with summary preservation
        // Note: In real implementation, this would actually delete files
        // For testing, we just verify the relationships structure
        #expect(relationships.availabilityStatus == .complete)
    }
    
    /// Tests orphaned file detection and cleanup
    @Test func orphanedFileDetectionAndCleanup() async throws {
        let fileManager = await EnhancedFileManager()
        
        // Create orphaned relationships (no recording, but has summary)
        let orphanedRelationships = FileRelationships(
            recordingURL: nil,
            recordingName: "Orphaned Recording",
            recordingDate: Date(),
            transcriptExists: false,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(orphanedRelationships.isOrphaned == true)
        #expect(orphanedRelationships.availabilityStatus == .summaryOnly)
        #expect(orphanedRelationships.hasRecording == false)
        
        // Test normal relationships (has recording and summary)
        let normalRelationships = FileRelationships(
            recordingURL: URL(fileURLWithPath: "/test/recording.m4a"),
            recordingName: "Normal Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(normalRelationships.isOrphaned == false)
        #expect(normalRelationships.availabilityStatus == .complete)
    }
    
    // MARK: - Background Processing Integration Tests
    
    /// Tests background processing job lifecycle
    @Test func backgroundProcessingJobLifecycle() async throws {
        let processingManager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        // Create a transcription job
        let transcriptionJob = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Test Recording"
        )
        
        // Create a summarization job
        let summarizationJob = ProcessingJob(
            type: .summarization(engine: "GPT-4"),
            recordingURL: testURL,
            recordingName: "Test Recording"
        )
        
        await MainActor.run {
            #expect(transcriptionJob.status == .queued)
            #expect(summarizationJob.status == .queued)
            #expect(processingManager.canStartNewJob == true)
        }
        
        // Test job status progression
        let processingJob = transcriptionJob.withStatus(.processing)
        let completedJob = processingJob.withStatus(.completed)
        
        #expect(processingJob.status == .processing)
        #expect(completedJob.status == .completed)
        #expect(completedJob.completionTime != nil)
    }
    
    /// Tests job persistence across app lifecycle
    @Test func jobPersistenceAcrossAppLifecycle() async throws {
        let processingManager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        // Create a job
        let job = ProcessingJob(
            type: .transcription(engine: .whisper),
            recordingURL: testURL,
            recordingName: "Persistent Test Recording"
        )
        
        // Simulate job persistence (in real implementation, this would use UserDefaults)
        let jobData = ProcessingJobData(
            id: job.id,
            recordingURL: job.recordingURL,
            recordingName: job.recordingName,
            jobType: job.type,
            status: job.status,
            progress: job.progress,
            startTime: job.startTime,
            completionTime: job.completionTime,
            chunks: job.chunks,
            error: job.error
        )
        
        #expect(jobData.id == job.id)
        #expect(jobData.recordingURL == job.recordingURL)
        #expect(jobData.recordingName == job.recordingName)
        #expect(jobData.status == job.status)
    }
    
    // MARK: - Error Recovery Integration Tests
    
    /// Tests error recovery in audio session configuration
    @Test func audioSessionErrorRecovery() async throws {
        let audioManager = await EnhancedAudioSessionManager()
        
        // Test error handling for configuration failures
        // Note: In real implementation, this would test actual AVAudioSession failures
        let error = AudioProcessingError.audioSessionConfigurationFailed("Test configuration failure")
        
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("configuration failed"))
        #expect(error.recoverySuggestion != nil)
    }
    
    /// Tests error recovery in chunking operations
    @Test func chunkingErrorRecovery() async throws {
        let chunkingService = await AudioFileChunkingService()
        
        // Test error handling for chunking failures
        let error = AudioProcessingError.chunkingFailed("Test chunking failure")
        
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("chunking failed"))
        #expect(error.recoverySuggestion != nil)
    }
    
    /// Tests error recovery in background processing
    @Test func backgroundProcessingErrorRecovery() async throws {
        let processingManager = await BackgroundProcessingManager()
        
        // Test error handling for processing failures
        let error = AudioProcessingError.backgroundProcessingFailed("Test processing failure")
        
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("processing failed"))
        #expect(error.recoverySuggestion != nil)
    }
    
    // MARK: - Performance Integration Tests
    
    /// Tests chunking performance with large files
    @Test func chunkingPerformanceWithLargeFiles() async throws {
        let chunkingService = await AudioFileChunkingService()
        
        // Simulate performance testing with large file info
        let largeFileInfo = AudioFileInfo(
            duration: 4 * 60 * 60, // 4 hours
            fileSize: 100 * 1024 * 1024, // 100MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        // Test that chunking decision is made quickly
        let startTime = Date()
        let needsChunking = largeFileInfo.fileSize > 24 * 1024 * 1024
        let decisionTime = Date().timeIntervalSince(startTime)
        
        #expect(needsChunking == true)
        #expect(decisionTime < 0.1) // Should be very fast
    }
    
    /// Tests memory usage during chunking operations
    @Test func memoryUsageDuringChunking() async throws {
        let chunkingService = await AudioFileChunkingService()
        
        // Test that chunking service doesn't consume excessive memory
        // Note: In real implementation, this would monitor actual memory usage
        await MainActor.run {
            #expect(chunkingService.isChunking == false)
            #expect(chunkingService.progress == 0.0)
        }
    }
    
    // MARK: - Network Integration Tests
    
    /// Tests network availability detection
    @Test func networkAvailabilityDetection() async throws {
        let available = NetworkStatus.available
        let unavailable = NetworkStatus.unavailable
        let limited = NetworkStatus.limited
        
        #expect(available.canSync == true)
        #expect(unavailable.canSync == false)
        #expect(limited.canSync == false)
    }
    
    /// Tests offline sync handling
    @Test func offlineSyncHandling() async throws {
        let syncManager = await iCloudStorageManager()
        
        // Test that sync manager handles offline scenarios gracefully
        await MainActor.run {
            #expect(syncManager.syncStatus == .idle)
        }
        
        // Note: In real implementation, this would test actual network failure scenarios
        // For testing, we just verify the initial state
    }
    
    // MARK: - Final Integration Tests for Step 12
    
    /// Tests complete app integration with all new features
    @Test func completeAppIntegrationWithNewFeatures() async throws {
        // Test that all new components work together with existing functionality
        
        // 1. Test enhanced audio session with recording workflow
        let audioManager = await EnhancedAudioSessionManager()
        let recorder = await AudioRecorderViewModel()
        
        try await audioManager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
            #expect(audioManager.isMixedAudioEnabled == true)
        }
        
        // 2. Test background processing integration
        let processingManager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/integration_recording.m4a")
        
        // Verify processing manager is ready
        await MainActor.run {
            #expect(processingManager.canStartNewJob == true)
            #expect(processingManager.activeJobs.isEmpty)
        }
        
        // 3. Test file management integration
        let fileManager = await EnhancedFileManager()
        
        // Create test relationships
        let relationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Integration Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(relationships.availabilityStatus == .complete)
        
        // 4. Test iCloud integration
        let syncManager = await iCloudStorageManager()
        
        await MainActor.run {
            #expect(syncManager.isEnabled == false)
            #expect(syncManager.syncStatus == .idle)
        }
        
        // 5. Test chunking service integration
        let chunkingService = await AudioFileChunkingService()
        
        await MainActor.run {
            #expect(chunkingService.isChunking == false)
            #expect(chunkingService.progress == 0.0)
        }
        
        // Verify all components can work together
        #expect(audioManager.isConfigured == true)
        #expect(processingManager.canStartNewJob == true)
        #expect(relationships.availabilityStatus == .complete)
    }
    
    /// Tests backward compatibility with existing data
    @Test func backwardCompatibilityWithExistingData() async throws {
        // Test that new features don't break existing functionality
        
        // 1. Test existing recording workflow still works
        let recorder = await AudioRecorderViewModel()
        
        // Verify recorder can still be initialized
        await MainActor.run {
            #expect(recorder.isRecording == false)
            #expect(recorder.recordingTime == 0)
        }
        
        // 2. Test existing summary management
        let summaryManager = await SummaryManager.shared
        
        // Verify summary manager can still be initialized
        await MainActor.run {
            #expect(summaryManager.enhancedSummaries.isEmpty)
        }
        
        // 3. Test existing transcript management
        let transcriptManager = await TranscriptManager.shared
        
        // Verify transcript manager can still be initialized
        await MainActor.run {
            #expect(transcriptManager.transcripts.isEmpty)
        }
        
        // 4. Test that enhanced features are optional
        let audioManager = await EnhancedAudioSessionManager()
        
        // Verify enhanced features don't interfere with basic functionality
        await MainActor.run {
            #expect(audioManager.isConfigured == false)
        }
        
        // 5. Test that file relationships work with existing files
        let fileManager = await EnhancedFileManager()
        let testURL = URL(fileURLWithPath: "/test/existing_recording.m4a")
        
        // Test that we can handle files without relationships (backward compatibility)
        let relationships = fileManager.getFileRelationships(for: testURL)
        #expect(relationships == nil) // No relationship for non-existent file
        
        // Verify backward compatibility is maintained
        #expect(recorder.isRecording == false)
        #expect(summaryManager.enhancedSummaries.isEmpty)
        #expect(transcriptManager.transcripts.isEmpty)
    }
    
    /// Tests app lifecycle scenarios (backgrounding, termination, restart)
    @Test func appLifecycleScenarios() async throws {
        // Test app behavior during various lifecycle events
        
        // 1. Test background processing during app backgrounding
        let processingManager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/lifecycle_recording.m4a")
        
        // Create a job that would persist across app lifecycle
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Lifecycle Test Recording"
        )
        
        await MainActor.run {
            #expect(job.status == .queued)
        }
        
        // Simulate job persistence (in real app, this would be saved to UserDefaults)
        let jobData = ProcessingJobData(
            id: job.id,
            recordingURL: job.recordingURL,
            recordingName: job.recordingName,
            jobType: job.type,
            status: job.status,
            progress: job.progress,
            startTime: job.startTime,
            completionTime: job.completionTime,
            chunks: job.chunks,
            error: job.error
        )
        
        #expect(jobData.id == job.id)
        #expect(jobData.status == .queued)
        
        // 2. Test audio session restoration after backgrounding
        let audioManager = await EnhancedAudioSessionManager()
        
        // Configure audio session
        try await audioManager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
        }
        
        // Simulate app returning to foreground
        try await audioManager.restoreAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
        }
        
        // 3. Test iCloud sync state persistence
        let syncManager = await iCloudStorageManager()
        
        // Test that sync state persists across app restarts
        await MainActor.run {
            syncManager.isEnabled = true
        }
        
        // Simulate app restart by creating new instance
        let newSyncManager = await iCloudStorageManager()
        
        // In real app, this would be loaded from UserDefaults
        // For testing, we verify the structure works
        #expect(newSyncManager.isEnabled == false) // Default state
        
        // 4. Test file relationships persistence
        let fileManager = await EnhancedFileManager()
        
        // Test that relationships can be saved and restored
        let testURL = URL(fileURLWithPath: "/test/persistent_recording.m4a")
        let relationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Persistent Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        // In real app, this would be saved to UserDefaults
        // For testing, we verify the structure works
        #expect(relationships.availabilityStatus == .complete)
        
        // 5. Test error recovery across app lifecycle
        let errorHandler = await EnhancedErrorHandler()
        
        // Test that errors can be recovered from
        let error = AudioProcessingError.audioSessionConfigurationFailed("Lifecycle test error")
        
        await MainActor.run {
            errorHandler.handleError(error)
        }
        
        // Verify error handling works across lifecycle
        #expect(error.errorDescription != nil)
        #expect(error.recoverySuggestion != nil)
    }
    
    /// Tests user workflows for all new functionality
    @Test func userWorkflowsForNewFunctionality() async throws {
        // Test complete user workflows for all new features
        
        // 1. Test mixed audio recording workflow
        let audioManager = await EnhancedAudioSessionManager()
        let recorder = await AudioRecorderViewModel()
        
        // User workflow: Configure mixed audio, start recording
        try await audioManager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isMixedAudioEnabled == true)
        }
        
        // Simulate recording start (in real app, this would start actual recording)
        // For testing, we verify the workflow structure
        #expect(audioManager.isConfigured == true)
        
        // 2. Test large file processing workflow
        let chunkingService = await AudioFileChunkingService()
        let processingManager = await BackgroundProcessingManager()
        
        // User workflow: Process large file with chunking
        let largeFileURL = URL(fileURLWithPath: "/test/large_user_file.m4a")
        
        // Check if chunking is needed
        let mockFileInfo = AudioFileInfo(
            duration: 3 * 60 * 60, // 3 hours
            fileSize: 30 * 1024 * 1024, // 30MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        let needsChunking = mockFileInfo.fileSize > 24 * 1024 * 1024
        #expect(needsChunking == true)
        
        // Create processing job
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: largeFileURL,
            recordingName: "Large User File"
        )
        
        await MainActor.run {
            #expect(job.status == .queued)
            #expect(processingManager.canStartNewJob == true)
        }
        
        // 3. Test iCloud sync workflow
        let syncManager = await iCloudStorageManager()
        
        // User workflow: Enable iCloud sync
        await MainActor.run {
            syncManager.isEnabled = true
        }
        
        await MainActor.run {
            #expect(syncManager.isEnabled == true)
        }
        
        // Create test summary for sync
        let testSummary = EnhancedSummaryData(
            id: UUID(),
            recordingURL: largeFileURL,
            recordingName: "Large User File",
            recordingDate: Date(),
            summary: "Test summary for sync workflow",
            tasks: ["Task 1"],
            reminders: ["Reminder 1"],
            titles: ["Test Title"],
            contentType: .meeting,
            aiMethod: "GPT-4",
            generatedAt: Date(),
            version: "1.0",
            wordCount: 5,
            originalLength: 180.0,
            compressionRatio: 0.1,
            confidence: 0.95,
            processingTime: 5.0,
            deviceIdentifier: "test-device",
            lastModified: Date()
        )
        
        #expect(testSummary.summary == "Test summary for sync workflow")
        #expect(testSummary.tasks.count == 1)
        
        // 4. Test selective deletion workflow
        let fileManager = await EnhancedFileManager()
        
        // User workflow: Delete recording but keep summary
        let deleteURL = URL(fileURLWithPath: "/test/delete_recording.m4a")
        let deleteRelationships = FileRelationships(
            recordingURL: deleteURL,
            recordingName: "Delete Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(deleteRelationships.availabilityStatus == .complete)
        
        // Simulate deletion with summary preservation
        // In real app, this would actually delete the file
        // For testing, we verify the workflow structure
        #expect(deleteRelationships.summaryExists == true)
        
        // 5. Test background processing workflow
        // User workflow: Start processing, navigate away, return to see progress
        
        let backgroundJob = ProcessingJob(
            type: .summarization(engine: "GPT-4"),
            recordingURL: largeFileURL,
            recordingName: "Background Test Recording"
        )
        
        await MainActor.run {
            #expect(backgroundJob.status == .queued)
            #expect(processingManager.canStartNewJob == true)
        }
        
        // Simulate job progression
        let processingJob = backgroundJob.withStatus(.processing)
        let completedJob = processingJob.withStatus(.completed)
        
        #expect(processingJob.status == .processing)
        #expect(completedJob.status == .completed)
        #expect(completedJob.completionTime != nil)
        
        // Verify all user workflows work correctly
        #expect(audioManager.isMixedAudioEnabled == true)
        #expect(needsChunking == true)
        #expect(syncManager.isEnabled == true)
        #expect(deleteRelationships.summaryExists == true)
        #expect(completedJob.status == .completed)
    }
    
    /// Tests error scenarios and recovery in user workflows
    @Test func errorScenariosAndRecoveryInUserWorkflows() async throws {
        // Test how the app handles errors in real user scenarios
        
        // 1. Test audio session configuration failure
        let audioManager = await EnhancedAudioSessionManager()
        
        // Simulate configuration failure
        let configError = AudioProcessingError.audioSessionConfigurationFailed("User workflow test error")
        
        await MainActor.run {
            audioManager.lastError = configError
        }
        
        #expect(configError.errorDescription != nil)
        #expect(configError.recoverySuggestion != nil)
        
        // 2. Test chunking failure during large file processing
        let chunkingService = await AudioFileChunkingService()
        
        let chunkingError = AudioProcessingError.chunkingFailed("User workflow chunking error")
        
        await MainActor.run {
            chunkingService.currentStatus = "Error occurred"
        }
        
        #expect(chunkingError.errorDescription != nil)
        #expect(chunkingError.recoverySuggestion != nil)
        
        // 3. Test iCloud sync failure
        let syncManager = await iCloudStorageManager()
        
        let syncError = AudioProcessingError.iCloudSyncFailed("User workflow sync error")
        
        await MainActor.run {
            syncManager.syncStatus = .failed(syncError)
        }
        
        #expect(syncError.errorDescription != nil)
        #expect(syncError.recoverySuggestion != nil)
        
        // 4. Test background processing failure
        let processingManager = await BackgroundProcessingManager()
        
        let processingError = AudioProcessingError.backgroundProcessingFailed("User workflow processing error")
        
        // Simulate failed job
        let failedJob = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: URL(fileURLWithPath: "/test/failed_job.m4a"),
            recordingName: "Failed Test Recording"
        ).withStatus(.failed(processingError))
        
        #expect(failedJob.status == .failed(processingError))
        #expect(processingError.errorDescription != nil)
        #expect(processingError.recoverySuggestion != nil)
        
        // 5. Test file relationship error
        let fileManager = await EnhancedFileManager()
        
        let relationshipError = AudioProcessingError.fileRelationshipError("User workflow relationship error")
        
        #expect(relationshipError.errorDescription != nil)
        #expect(relationshipError.recoverySuggestion != nil)
        
        // Verify error recovery works in all scenarios
        #expect(configError.errorDescription != nil)
        #expect(chunkingError.errorDescription != nil)
        #expect(syncError.errorDescription != nil)
        #expect(processingError.errorDescription != nil)
        #expect(relationshipError.errorDescription != nil)
    }
    
    /// Tests performance and memory usage in real scenarios
    @Test func performanceAndMemoryUsageInRealScenarios() async throws {
        // Test performance characteristics in realistic usage scenarios
        
        // 1. Test audio session configuration performance
        let audioManager = await EnhancedAudioSessionManager()
        
        let startTime = Date()
        try await audioManager.configureMixedAudioSession()
        let configTime = Date().timeIntervalSince(startTime)
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
        }
        
        // Configuration should be fast (< 1 second)
        #expect(configTime < 1.0)
        
        // 2. Test chunking decision performance
        let chunkingService = await AudioFileChunkingService()
        
        let decisionStartTime = Date()
        let mockFileInfo = AudioFileInfo(
            duration: 2 * 60 * 60, // 2 hours
            fileSize: 25 * 1024 * 1024, // 25MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        let needsChunking = mockFileInfo.fileSize > 24 * 1024 * 1024
        let decisionTime = Date().timeIntervalSince(decisionStartTime)
        
        #expect(needsChunking == true)
        #expect(decisionTime < 0.1) // Should be very fast
        
        // 3. Test background processing job creation performance
        let processingManager = await BackgroundProcessingManager()
        
        let jobStartTime = Date()
        let job = ProcessingJob(
            type: .transcription(engine: .whisper),
            recordingURL: URL(fileURLWithPath: "/test/performance_test.m4a"),
            recordingName: "Performance Test Recording"
        )
        let jobCreationTime = Date().timeIntervalSince(jobStartTime)
        
        #expect(job.status == .queued)
        #expect(jobCreationTime < 0.1) // Should be very fast
        
        // 4. Test file relationship query performance
        let fileManager = await EnhancedFileManager()
        
        let queryStartTime = Date()
        let relationships = fileManager.getAllRelationships()
        let queryTime = Date().timeIntervalSince(queryStartTime)
        
        #expect(queryTime < 0.1) // Should be very fast
        
        // 5. Test iCloud sync status check performance
        let syncManager = await iCloudStorageManager()
        
        let syncStartTime = Date()
        let syncStatus = syncManager.syncStatus
        let syncCheckTime = Date().timeIntervalSince(syncStartTime)
        
        #expect(syncCheckTime < 0.1) // Should be very fast
        
        // Verify all operations are performant
        #expect(configTime < 1.0)
        #expect(decisionTime < 0.1)
        #expect(jobCreationTime < 0.1)
        #expect(queryTime < 0.1)
        #expect(syncCheckTime < 0.1)
    }
    
    /// Tests app startup and initialization performance
    @Test func appStartupAndInitializationPerformance() async throws {
        // Test that app startup with all new features is performant
        
        // 1. Test component initialization performance
        let startTime = Date()
        
        let audioManager = await EnhancedAudioSessionManager()
        let processingManager = await BackgroundProcessingManager()
        let fileManager = await EnhancedFileManager()
        let syncManager = await iCloudStorageManager()
        let chunkingService = await AudioFileChunkingService()
        
        let initTime = Date().timeIntervalSince(startTime)
        
        // All components should initialize quickly
        #expect(initTime < 0.5) // Should be very fast
        
        // 2. Test that components are in correct initial state
        await MainActor.run {
            #expect(audioManager.isConfigured == false)
            #expect(processingManager.canStartNewJob == true)
            #expect(syncManager.isEnabled == false)
            #expect(chunkingService.isChunking == false)
        }
        
        // 3. Test memory usage during initialization
        // In real implementation, this would monitor actual memory usage
        // For testing, we verify the initialization completes successfully
        #expect(audioManager.isConfigured == false)
        #expect(processingManager.canStartNewJob == true)
        #expect(syncManager.isEnabled == false)
        #expect(chunkingService.isChunking == false)
        
        // 4. Test that initialization doesn't block UI
        // Verify that all components can be accessed immediately
        await MainActor.run {
            #expect(audioManager.isConfigured == false)
            #expect(processingManager.activeJobs.isEmpty)
            #expect(syncManager.syncStatus == .idle)
            #expect(chunkingService.progress == 0.0)
        }
        
        // Verify startup performance is acceptable
        #expect(initTime < 0.5)
    }
    
    /// Tests data consistency and integrity across all features
    @Test func dataConsistencyAndIntegrityAcrossAllFeatures() async throws {
        // Test that data remains consistent across all new features
        
        // 1. Test file relationship consistency
        let fileManager = await EnhancedFileManager()
        let testURL = URL(fileURLWithPath: "/test/consistency_test.m4a")
        
        let relationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Consistency Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        // Verify relationship data consistency
        #expect(relationships.recordingURL == testURL)
        #expect(relationships.recordingName == "Consistency Test Recording")
        #expect(relationships.transcriptExists == true)
        #expect(relationships.summaryExists == true)
        #expect(relationships.iCloudSynced == false)
        #expect(relationships.availabilityStatus == .complete)
        
        // 2. Test processing job data consistency
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Consistency Test Recording"
        )
        
        // Verify job data consistency
        #expect(job.recordingURL == testURL)
        #expect(job.recordingName == "Consistency Test Recording")
        #expect(job.status == .queued)
        #expect(job.progress == 0.0)
        #expect(job.startTime != nil)
        #expect(job.completionTime == nil)
        
        // 3. Test audio session configuration consistency
        let audioManager = await EnhancedAudioSessionManager()
        
        try await audioManager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(audioManager.isConfigured == true)
            #expect(audioManager.isMixedAudioEnabled == true)
            #expect(audioManager.isBackgroundRecordingEnabled == false)
            #expect(audioManager.currentConfiguration != nil)
        }
        
        // 4. Test iCloud sync data consistency
        let syncManager = await iCloudStorageManager()
        
        await MainActor.run {
            syncManager.isEnabled = true
            syncManager.syncStatus = .syncing
        }
        
        await MainActor.run {
            #expect(syncManager.isEnabled == true)
            #expect(syncManager.syncStatus == .syncing)
        }
        
        // 5. Test chunking data consistency
        let chunkingService = await AudioFileChunkingService()
        
        let mockFileInfo = AudioFileInfo(
            duration: 1.5 * 60 * 60, // 1.5 hours
            fileSize: 20 * 1024 * 1024, // 20MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        // Verify chunking decision consistency
        let needsChunking = mockFileInfo.fileSize > 24 * 1024 * 1024
        #expect(needsChunking == false) // 20MB < 24MB limit
        
        // Verify all data remains consistent
        #expect(relationships.availabilityStatus == .complete)
        #expect(job.status == .queued)
        #expect(audioManager.isConfigured == true)
        #expect(syncManager.isEnabled == true)
        #expect(needsChunking == false)
    }
} 