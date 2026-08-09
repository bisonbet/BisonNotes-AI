//
//  AudioTranscriptionRegressionTests.swift
//  BisonNotes AITests
//

import AVFoundation
import XCTest
@testable import BisonNotes_AI

final class AudioTranscriptionRegressionTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
    }

    func testRemovedTranscriptionEngineJobWaitsForConfiguredReplacement() throws {
        let payload = """
        {"type":"transcription","engine":"OpenAI"}
        """.data(using: .utf8)!

        let jobType = try JSONDecoder().decode(JobType.self, from: payload)

        guard case .transcription(let engine) = jobType else {
            return XCTFail("Expected a transcription job")
        }
        XCTAssertEqual(engine, .notConfigured)
    }

    func testValidShortAudioFixtureProducesAudioFileInfo() async throws {
        let audioURL = tempDirectory.appendingPathComponent("valid-short.caf")
        try createSilentAudioFixture(at: audioURL, duration: 1.0)

        let info = try await AudioFileInfo.create(from: audioURL)

        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertGreaterThan(info.fileSize, 0)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 16_000, accuracy: 1)
    }

    func testEmptyAudioFileIsRejectedBeforeTranscriptionWorkStarts() async throws {
        let audioURL = tempDirectory.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        do {
            _ = try await AudioFileInfo.create(from: audioURL)
            XCTFail("Expected empty audio to be rejected")
        } catch {
            XCTAssertTrue(true)
        }
    }

    @MainActor
    func testTranscriptReassemblySortsChunksAndOffsetsSegments() async throws {
        let service = AudioFileChunkingService()
        let recordingId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("original.m4a")
        let secondChunk = TranscriptChunk(
            chunkId: UUID(),
            sequenceNumber: 1,
            transcript: "second",
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "second", startTime: 0, endTime: 1)],
            startTime: 10,
            endTime: 11
        )
        let firstChunk = TranscriptChunk(
            chunkId: UUID(),
            sequenceNumber: 0,
            transcript: "first",
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "first", startTime: 0, endTime: 1)],
            startTime: 0,
            endTime: 1
        )

        let result = try await service.reassembleTranscript(
            from: [secondChunk, firstChunk],
            originalURL: originalURL,
            recordingName: "Chunked Recording",
            recordingDate: Date(),
            recordingId: recordingId
        )

        XCTAssertEqual(result.transcriptData.recordingId, recordingId)
        XCTAssertEqual(result.transcriptData.segments.map(\.text), ["first", "second"])
        XCTAssertEqual(result.transcriptData.segments.map(\.startTime), [0, 10])
        XCTAssertEqual(result.totalSegments, 2)
    }

    @MainActor
    func testMissingRecordingIdentityFailsBeforeTranscriptPersistence() throws {
        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let audioURL = tempDirectory.appendingPathComponent("missing-identity.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = coordinator.addRecording(
            url: audioURL,
            name: "Missing Identity",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )

        let transcriptData = TranscriptData(
            recordingURL: audioURL,
            recordingName: "Missing Identity",
            recordingDate: Date(),
            segments: [TranscriptSegment(speaker: "Speaker", text: "Unsaved transcript", startTime: 0, endTime: 1)]
        )

        XCTAssertThrowsError(try persistBackgroundTranscript(transcriptData, using: coordinator)) { error in
            guard case .recordingIdentityUnavailable(let failedURL) = error as? BackgroundProcessingError else {
                return XCTFail("Expected a typed recording identity error")
            }
            XCTAssertEqual(failedURL, audioURL)
        }
        XCTAssertNil(coordinator.getTranscriptData(for: recordingId))
    }

    @MainActor
    func testBackgroundTranscriptPersistenceReturnsSavedIdentity() throws {
        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let audioURL = tempDirectory.appendingPathComponent("persisted-transcript.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = coordinator.addRecording(
            url: audioURL,
            name: "Persisted Transcript",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptData = TranscriptData(
            recordingId: recordingId,
            recordingURL: audioURL,
            recordingName: "Persisted Transcript",
            recordingDate: Date(),
            segments: [TranscriptSegment(speaker: "Speaker", text: "Persist this transcript", startTime: 0, endTime: 1)],
            engine: .fluidAudio,
            processingTime: 0.5,
            confidence: 0.9
        )

        let transcriptId = try persistBackgroundTranscript(transcriptData, using: coordinator)

        XCTAssertEqual(coordinator.getTranscript(for: recordingId)?.id, transcriptId)
        XCTAssertEqual(coordinator.getTranscriptData(for: recordingId)?.recordingId, recordingId)
        XCTAssertEqual(coordinator.getTranscriptData(for: recordingId)?.plainText, "Persist this transcript")
    }

    @MainActor
    func testActiveTranscriptionJobDetectionUsesFilenameWithoutDiskIO() throws {
        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let audioURL = tempDirectory.appendingPathComponent("active-job.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = coordinator.addRecording(
            url: audioURL,
            name: "Active Job",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let recording = try XCTUnwrap(coordinator.getRecording(id: recordingId))

        let manager = BackgroundProcessingManager.shared
        let oldJobs = manager.activeJobs
        defer { manager.activeJobs = oldJobs }

        let queuedJob = ProcessingJob(
            type: .transcription(engine: .fluidAudio),
            recordingURL: audioURL,
            recordingName: "Active Job"
        ).withStatus(.queued)
        manager.activeJobs = [queuedJob]

        XCTAssertTrue(TranscriptionStarter.shared.hasActiveTranscriptionJob(for: recording, appCoordinator: coordinator))
        XCTAssertEqual(
            TranscriptionStarter.shared.activeTranscriptionJobStatus(for: recording, appCoordinator: coordinator),
            .queued
        )
    }

    private func createSilentAudioFixture(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }
}
