//
//  Audio_JournalTests.swift
//  Audio JournalTests
//
//  Created by Tim Champ on 7/26/25.
//

import Testing
@testable import Audio_Journal

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
    


}
