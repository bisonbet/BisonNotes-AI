//
//  BisonNotesAIIntegrationTests.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
@testable import BisonNotes_AI

@MainActor
final class BisonNotesAIIntegrationTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        appCoordinator = AppDataCoordinator(persistenceController: persistenceController)
        tempDirectory = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
        appCoordinator = nil
        persistenceController = nil
    }

    @MainActor
    func testRecordingTranscriptSummaryStayLinkedByUUID() throws {
        let audioURL = tempDirectory.appendingPathComponent("workflow-recording.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)

        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: "Workflow Recording",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            fileSize: 1_024,
            duration: 60,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [
                TranscriptSegment(speaker: "Speaker 1", text: "Discuss the release checklist.", startTime: 0, endTime: 3)
            ],
            engine: .fluidAudio,
            processingTime: 0.2,
            confidence: 0.95
        ))
        let summaryId = try XCTUnwrap(appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Release checklist discussion with enough detail to be considered a real generated summary.",
            tasks: [TaskItem(text: "Run the regression gate")],
            titles: [TitleItem(text: "Release Checklist")],
            contentType: .meeting,
            aiEngine: "Test",
            aiModel: "fixture",
            originalLength: 80,
            processingTime: 0.1
        ))

        let complete = try XCTUnwrap(appCoordinator.getCompleteRecordingData(id: recordingId))
        XCTAssertEqual(complete.recording.id, recordingId)
        XCTAssertEqual(complete.recording.transcriptId, transcriptId)
        XCTAssertEqual(complete.recording.summaryId, summaryId)
        XCTAssertEqual(complete.transcript?.recordingId, recordingId)
        XCTAssertEqual(complete.summary?.recordingId, recordingId)
        XCTAssertEqual(complete.summary?.transcriptId, transcriptId)
    }

    @MainActor
    func testTranscriptReplacementPreservesTranscriptIdAndUpdatesSegments() throws {
        let recordingId = try createRecording(named: "Transcript Replacement")
        let firstId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Old text", startTime: 0, endTime: 1)]
        ))

        let secondId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "New replacement text", startTime: 0, endTime: 2)],
            engine: .openAI,
            confidence: 0.9
        ))

        let transcript = try XCTUnwrap(appCoordinator.getTranscriptData(for: recordingId))
        XCTAssertEqual(secondId, firstId)
        XCTAssertEqual(transcript.segments.map(\.text), ["New replacement text"])
        XCTAssertEqual(transcript.engine, .openAI)
    }

    @MainActor
    func testShortSummaryIsRejectedWithoutReplacingExistingSummary() throws {
        let recordingId = try createRecording(named: "Summary Guard")
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Enough transcript text", startTime: 0, endTime: 2)]
        ))
        let existingSummaryId = try XCTUnwrap(appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "This existing summary is long enough to be persisted before a failed regeneration attempt.",
            aiModel: "fixture",
            originalLength: 60
        ))

        let rejected = appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Too short",
            aiModel: "fixture",
            originalLength: 9
        )

        let summary = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertNil(rejected)
        XCTAssertEqual(summary.id, existingSummaryId)
    }

    @MainActor
    private func createRecording(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        return appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 10,
            quality: .whisperOptimized
        )
    }
}
