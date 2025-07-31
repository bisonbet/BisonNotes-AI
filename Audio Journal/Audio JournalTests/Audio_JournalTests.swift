//
//  Audio_JournalTests.swift
//  Audio JournalTests
//
//  Created by Tim Champ on 7/26/25.
//

import Testing
@testable import Audio_Journal
import AVFoundation

struct Audio_JournalTests {

    /// Ensures that chunkText splits a small sample into the
    /// correct number of chunks when a low maxTokens value is used.
    @Test func chunkTextSplitsSmallSample() async throws {
        let sample = "Hello world. This is a test. Short sentence."

        let chunks = TokenManager.chunkText(sample, maxTokens: 4)

        #expect(chunks.count == 3)
        #expect(chunks[0] == "Hello world.")
        #expect(chunks[1] == "This is a test.")
        #expect(chunks[2] == "Short sentence.")
    }
    
    /// Tests that EnhancedAudioSessionManager initializes correctly
    @Test func enhancedAudioSessionManagerInitialization() async throws {
        let manager = await EnhancedAudioSessionManager()
        
        await MainActor.run {
            #expect(manager.isConfigured == false)
            #expect(manager.isMixedAudioEnabled == false)
            #expect(manager.isBackgroundRecordingEnabled == false)
            #expect(manager.currentConfiguration == nil)
        }
    }
    
    /// Tests that audio session configurations are created correctly
    @Test func audioSessionConfigurationCreation() async throws {
        let mixedConfig = EnhancedAudioSessionManager.AudioSessionConfig.mixedAudioRecording
        let backgroundConfig = EnhancedAudioSessionManager.AudioSessionConfig.backgroundRecording
        let standardConfig = EnhancedAudioSessionManager.AudioSessionConfig.standardRecording
        
        #expect(mixedConfig.allowMixedAudio == true)
        #expect(mixedConfig.backgroundRecording == false)
        #expect(mixedConfig.options.contains(.mixWithOthers))
        
        #expect(backgroundConfig.allowMixedAudio == true)
        #expect(backgroundConfig.backgroundRecording == true)
        #expect(backgroundConfig.options.contains(.mixWithOthers))
        
        #expect(standardConfig.allowMixedAudio == false)
        #expect(standardConfig.backgroundRecording == false)
        #expect(!standardConfig.options.contains(.mixWithOthers))
    }
    
    /// Tests that AudioFileChunkingService initializes correctly
    @Test func audioFileChunkingServiceInitialization() async throws {
        let service = await AudioFileChunkingService()
        
        await MainActor.run {
            #expect(service.isChunking == false)
            #expect(service.currentStatus == "")
            #expect(service.progress == 0.0)
        }
    }
    
    /// Tests that chunking strategies are configured correctly for different engines
    @Test func chunkingStrategyConfiguration() async throws {
        let openAIConfig = ChunkingConfig.config(for: .openAI)
        let whisperConfig = ChunkingConfig.config(for: .whisper)
        let awsConfig = ChunkingConfig.config(for: .awsTranscribe)
        let appleConfig = ChunkingConfig.config(for: .appleIntelligence)
        
        // Test OpenAI file size strategy
        if case .fileSize(let maxBytes) = openAIConfig.strategy {
            #expect(maxBytes == 24 * 1024 * 1024) // 24MB
        } else {
            #expect(Bool(false), "OpenAI should use file size strategy")
        }
        
        // Test Whisper duration strategy
        if case .duration(let maxSeconds) = whisperConfig.strategy {
            #expect(maxSeconds == 2 * 60 * 60) // 2 hours
        } else {
            #expect(Bool(false), "Whisper should use duration strategy")
        }
        
        // Test AWS duration strategy
        if case .duration(let maxSeconds) = awsConfig.strategy {
            #expect(maxSeconds == 2 * 60 * 60) // 2 hours
        } else {
            #expect(Bool(false), "AWS should use duration strategy")
        }
        
        // Test Apple Intelligence duration strategy
        if case .duration(let maxSeconds) = appleConfig.strategy {
            #expect(maxSeconds == 15 * 60) // 15 minutes
        } else {
            #expect(Bool(false), "Apple Intelligence should use duration strategy")
        }
    }
    
    /// Tests that AudioChunk model is created correctly
    @Test func audioChunkModelCreation() async throws {
        let originalURL = URL(fileURLWithPath: "/test/original.m4a")
        let chunkURL = URL(fileURLWithPath: "/test/chunk_0.m4a")
        
        let chunk = AudioChunk(
            originalURL: originalURL,
            chunkURL: chunkURL,
            sequenceNumber: 0,
            startTime: 0.0,
            endTime: 60.0,
            fileSize: 1024 * 1024
        )
        
        #expect(chunk.originalURL == originalURL)
        #expect(chunk.chunkURL == chunkURL)
        #expect(chunk.sequenceNumber == 0)
        #expect(chunk.startTime == 0.0)
        #expect(chunk.endTime == 60.0)
        #expect(chunk.duration == 60.0)
        #expect(chunk.fileSize == 1024 * 1024)
    }
    
    /// Tests that TranscriptChunk model is created correctly
    @Test func transcriptChunkModelCreation() async throws {
        let chunkId = UUID()
        let segments = [
            TranscriptSegment(speaker: "Speaker", text: "Hello world", startTime: 0.0, endTime: 2.0)
        ]
        
        let transcriptChunk = TranscriptChunk(
            chunkId: chunkId,
            sequenceNumber: 0,
            transcript: "Hello world",
            segments: segments,
            startTime: 0.0,
            endTime: 60.0,
            processingTime: 5.0
        )
        
        #expect(transcriptChunk.chunkId == chunkId)
        #expect(transcriptChunk.sequenceNumber == 0)
        #expect(transcriptChunk.transcript == "Hello world")
        #expect(transcriptChunk.segments.count == 1)
        #expect(transcriptChunk.startTime == 0.0)
        #expect(transcriptChunk.endTime == 60.0)
        #expect(transcriptChunk.processingTime == 5.0)
    }
    
    // MARK: - Enhanced Audio Session Manager Tests
    
    /// Tests mixed audio session configuration
    @Test func configureMixedAudioSession() async throws {
        let manager = await EnhancedAudioSessionManager()
        
        try await manager.configureMixedAudioSession()
        
        await MainActor.run {
            #expect(manager.isConfigured == true)
            #expect(manager.isMixedAudioEnabled == true)
            #expect(manager.isBackgroundRecordingEnabled == false)
            #expect(manager.currentConfiguration != nil)
            #expect(manager.currentConfiguration?.allowMixedAudio == true)
        }
    }
    
    /// Tests background recording configuration
    @Test func configureBackgroundRecording() async throws {
        let manager = await EnhancedAudioSessionManager()
        
        try await manager.configureBackgroundRecording()
        
        await MainActor.run {
            #expect(manager.isConfigured == true)
            #expect(manager.isMixedAudioEnabled == true)
            #expect(manager.isBackgroundRecordingEnabled == true)
            #expect(manager.currentConfiguration != nil)
            #expect(manager.currentConfiguration?.backgroundRecording == true)
        }
    }
    
    /// Tests audio session restoration
    @Test func restoreAudioSession() async throws {
        let manager = await EnhancedAudioSessionManager()
        
        // First configure mixed audio
        try await manager.configureMixedAudioSession()
        
        // Then restore
        try await manager.restoreAudioSession()
        
        await MainActor.run {
            #expect(manager.isConfigured == true)
            #expect(manager.lastError == nil)
        }
    }
    
    /// Tests audio interruption handling
    @Test func handleAudioInterruption() async throws {
        let manager = await EnhancedAudioSessionManager()
        
        // Configure session first
        try await manager.configureMixedAudioSession()
        
        // Simulate interruption
        let notification = Notification(name: AVAudioSession.interruptionNotification)
        manager.handleAudioInterruption(notification)
        
        await MainActor.run {
            #expect(manager.isConfigured == true)
        }
    }
    
    // MARK: - Background Processing Manager Tests
    
    /// Tests BackgroundProcessingManager initialization
    @Test func backgroundProcessingManagerInitialization() async throws {
        let manager = await BackgroundProcessingManager()
        
        await MainActor.run {
            #expect(manager.activeJobs.isEmpty)
            #expect(manager.processingStatus == .idle)
            #expect(manager.canStartNewJob == true)
        }
    }
    
    /// Tests job creation and queuing
    @Test func jobCreationAndQueuing() async throws {
        let manager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Test Recording"
        )
        
        await MainActor.run {
            #expect(job.id != UUID())
            #expect(job.type == .transcription(engine: .openAI))
            #expect(job.recordingURL == testURL)
            #expect(job.recordingName == "Test Recording")
            #expect(job.status == .queued)
            #expect(job.progress == 0.0)
        }
    }
    
    /// Tests job status updates
    @Test func jobStatusUpdates() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Test Recording"
        )
        
        let updatedJob = job.withStatus(.processing)
        
        #expect(updatedJob.status == .processing)
        #expect(updatedJob.completionTime == nil)
        
        let completedJob = job.withStatus(.completed)
        
        #expect(completedJob.status == .completed)
        #expect(completedJob.completionTime != nil)
    }
    
    /// Tests job progress updates
    @Test func jobProgressUpdates() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        let job = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Test Recording"
        )
        
        let updatedJob = job.withProgress(0.5)
        
        #expect(updatedJob.progress == 0.5)
        #expect(updatedJob.status == .queued) // Status unchanged
    }
    
    /// Tests single job constraint
    @Test func singleJobConstraint() async throws {
        let manager = await BackgroundProcessingManager()
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        let job1 = ProcessingJob(
            type: .transcription(engine: .openAI),
            recordingURL: testURL,
            recordingName: "Test Recording 1"
        )
        
        let job2 = ProcessingJob(
            type: .transcription(engine: .whisper),
            recordingURL: testURL,
            recordingName: "Test Recording 2"
        )
        
        await MainActor.run {
            // Add first job
            manager.activeJobs.append(job1)
            #expect(manager.canStartNewJob == false)
            
            // Try to add second job - should not be allowed
            manager.activeJobs.append(job2)
            #expect(manager.activeJobs.count == 1) // Only first job should be there
        }
    }
    
    // MARK: - Audio File Chunking Service Tests
    
    /// Tests file size-based chunking decision for OpenAI
    @Test func fileSizeChunkingDecision() async throws {
        let service = await AudioFileChunkingService()
        
        // Create a mock file info for testing
        let mockFileInfo = AudioFileInfo(
            duration: 3600.0, // 1 hour
            fileSize: 25 * 1024 * 1024, // 25MB (exceeds 24MB limit)
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        // Mock the shouldChunkFile method behavior
        let needsChunking = mockFileInfo.fileSize > 24 * 1024 * 1024
        
        #expect(needsChunking == true)
    }
    
    /// Tests duration-based chunking decision for Whisper
    @Test func durationChunkingDecision() async throws {
        let service = await AudioFileChunkingService()
        
        // Create a mock file info for testing
        let mockFileInfo = AudioFileInfo(
            duration: 3 * 60 * 60, // 3 hours (exceeds 2 hour limit)
            fileSize: 10 * 1024 * 1024, // 10MB
            format: "m4a",
            sampleRate: 44100,
            channels: 2
        )
        
        // Mock the shouldChunkFile method behavior
        let needsChunking = mockFileInfo.duration > 2 * 60 * 60
        
        #expect(needsChunking == true)
    }
    
    /// Tests chunking result model
    @Test func chunkingResultModel() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        
        let chunk = AudioChunk(
            originalURL: testURL,
            chunkURL: testURL,
            sequenceNumber: 0,
            startTime: 0.0,
            endTime: 60.0,
            fileSize: 1024 * 1024
        )
        
        let result = ChunkingResult(
            chunks: [chunk],
            totalDuration: 60.0,
            totalSize: 1024 * 1024,
            chunkingTime: 5.0
        )
        
        #expect(result.chunks.count == 1)
        #expect(result.totalDuration == 60.0)
        #expect(result.totalSize == 1024 * 1024)
        #expect(result.chunkingTime == 5.0)
        #expect(result.chunkCount == 1)
    }
    
    // MARK: - iCloud Storage Manager Tests
    
    /// Tests iCloudStorageManager initialization
    @Test func iCloudStorageManagerInitialization() async throws {
        let manager = await iCloudStorageManager()
        
        await MainActor.run {
            #expect(manager.isEnabled == false)
            #expect(manager.syncStatus == .idle)
        }
    }
    
    /// Tests sync status enum
    @Test func syncStatusEnum() async throws {
        let idle = SyncStatus.idle
        let syncing = SyncStatus.syncing
        let completed = SyncStatus.completed
        let failed = SyncStatus.failed("Test error")
        
        #expect(idle.description == "Ready")
        #expect(syncing.description == "Syncing...")
        #expect(completed.description == "Synced")
        #expect(failed.description == "Failed: Test error")
        
        #expect(idle.isError == false)
        #expect(syncing.isError == false)
        #expect(completed.isError == false)
        #expect(failed.isError == true)
    }
    
    /// Tests CloudKit summary record structure
    @Test func cloudKitSummaryRecordStructure() async throws {
        #expect(CloudKitSummaryRecord.recordType == "EnhancedSummary")
        #expect(CloudKitSummaryRecord.recordingURLField == "recordingURL")
        #expect(CloudKitSummaryRecord.summaryField == "summary")
        #expect(CloudKitSummaryRecord.tasksField == "tasks")
        #expect(CloudKitSummaryRecord.remindersField == "reminders")
    }
    
    /// Tests conflict resolution strategy enum
    @Test func conflictResolutionStrategy() async throws {
        let strategies: [ConflictResolutionStrategy] = [
            .newerWins,
            .deviceWins,
            .cloudWins,
            .manual
        ]
        
        #expect(strategies.count == 4)
    }
    
    /// Tests network status enum
    @Test func networkStatusEnum() async throws {
        let available = NetworkStatus.available
        let unavailable = NetworkStatus.unavailable
        let limited = NetworkStatus.limited
        
        #expect(available.canSync == true)
        #expect(unavailable.canSync == false)
        #expect(limited.canSync == false)
    }
    
    // MARK: - Enhanced File Manager Tests
    
    /// Tests FileRelationships model creation
    @Test func fileRelationshipsModelCreation() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        let testDate = Date()
        
        let relationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Test Recording",
            recordingDate: testDate,
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(relationships.recordingURL == testURL)
        #expect(relationships.recordingName == "Test Recording")
        #expect(relationships.recordingDate == testDate)
        #expect(relationships.transcriptExists == true)
        #expect(relationships.summaryExists == true)
        #expect(relationships.iCloudSynced == false)
        #expect(relationships.isOrphaned == false)
    }
    
    /// Tests file availability status enum
    @Test func fileAvailabilityStatus() async throws {
        let complete = FileAvailabilityStatus.complete
        let recordingOnly = FileAvailabilityStatus.recordingOnly
        let summaryOnly = FileAvailabilityStatus.summaryOnly
        let transcriptOnly = FileAvailabilityStatus.transcriptOnly
        let none = FileAvailabilityStatus.none
        
        #expect(complete.icon == "checkmark.circle.fill")
        #expect(recordingOnly.icon == "waveform")
        #expect(summaryOnly.icon == "doc.text")
        #expect(transcriptOnly.icon == "text.quote")
        #expect(none.icon == "questionmark.circle")
        
        #expect(complete.color == "green")
        #expect(recordingOnly.color == "blue")
        #expect(summaryOnly.color == "orange")
        #expect(transcriptOnly.color == "purple")
        #expect(none.color == "gray")
    }
    
    /// Tests orphaned file detection
    @Test func orphanedFileDetection() async throws {
        // Test with no recording URL (orphaned)
        let orphanedRelationships = FileRelationships(
            recordingURL: nil,
            recordingName: "Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(orphanedRelationships.isOrphaned == true)
        #expect(orphanedRelationships.availabilityStatus == .summaryOnly)
        
        // Test with recording URL (not orphaned)
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        let normalRelationships = FileRelationships(
            recordingURL: testURL,
            recordingName: "Test Recording",
            recordingDate: Date(),
            transcriptExists: true,
            summaryExists: true,
            iCloudSynced: false
        )
        
        #expect(normalRelationships.isOrphaned == false)
        #expect(normalRelationships.availabilityStatus == .complete)
    }
    
    // MARK: - Error Handling Tests
    
    /// Tests AudioProcessingError types
    @Test func audioProcessingErrorTypes() async throws {
        let errors: [AudioProcessingError] = [
            .audioSessionConfigurationFailed("Test error"),
            .backgroundRecordingNotPermitted,
            .chunkingFailed("Chunking error"),
            .iCloudSyncFailed("Sync error"),
            .backgroundProcessingFailed("Processing error"),
            .fileRelationshipError("File error"),
            .recordingFailed("Recording error"),
            .playbackFailed("Playback error"),
            .formatConversionFailed("Conversion error"),
            .metadataExtractionFailed("Metadata error")
        ]
        
        #expect(errors.count == 10)
        
        // Test error descriptions
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
    
    /// Tests error recovery suggestions
    @Test func errorRecoverySuggestions() async throws {
        let error = AudioProcessingError.backgroundRecordingNotPermitted
        
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion!.contains("background audio"))
    }
    
    // MARK: - Data Model Tests
    
    /// Tests ProcessingJobData model
    @Test func processingJobDataModel() async throws {
        let testURL = URL(fileURLWithPath: "/test/recording.m4a")
        let testDate = Date()
        
        let jobData = ProcessingJobData(
            id: UUID(),
            recordingURL: testURL,
            recordingName: "Test Recording",
            jobType: .transcription(engine: .openAI),
            status: .queued,
            progress: 0.0,
            startTime: testDate,
            completionTime: nil,
            chunks: nil,
            error: nil
        )
        
        #expect(jobData.recordingURL == testURL)
        #expect(jobData.recordingName == "Test Recording")
        #expect(jobData.status == .queued)
        #expect(jobData.progress == 0.0)
        #expect(jobData.startTime == testDate)
        #expect(jobData.completionTime == nil)
    }
    
    /// Tests JobType enum
    @Test func jobTypeEnum() async throws {
        let transcriptionJob = JobType.transcription(engine: .openAI)
        let summarizationJob = JobType.summarization(engine: "GPT-4")
        
        #expect(transcriptionJob.displayName == "Transcription (openAI)")
        #expect(summarizationJob.displayName == "Summarization (GPT-4)")
    }
    
    /// Tests ProcessingStatus enum
    @Test func processingStatusEnum() async throws {
        let idle = ProcessingStatus.idle
        let queued = ProcessingStatus.queued
        let processing = ProcessingStatus.processing
        let completed = ProcessingStatus.completed
        let failed = ProcessingStatus.failed(AudioProcessingError.recordingFailed("Test"))
        
        #expect(idle.isError == false)
        #expect(queued.isError == false)
        #expect(processing.isError == false)
        #expect(completed.isError == false)
        #expect(failed.isError == true)
        
        #expect(failed.errorMessage != nil)
    }
}
