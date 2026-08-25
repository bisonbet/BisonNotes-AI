import XCTest
@testable import BisonNotes_AI

final class LocalDiarizationTextReconciliationTests: XCTestCase {
    func testCanonicalTranscriptReceivesLabelsWhenTimedTextMissesShortFragment() async throws {
        let fake = TextReconciliationDiarizer(
            intervals: [
                LocalDiarizationInterval(speakerID: "first", startTime: 0, endTime: 0.5),
                LocalDiarizationInterval(speakerID: "second", startTime: 0.5, endTime: 1)
            ]
        )
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = makeResult(
            text: "hello missing world",
            timedWords: [
                TimedTranscriptWord(text: "hello", startTime: 0, endTime: 0.4, hasLeadingSpace: false),
                TimedTranscriptWord(text: "world", startTime: 0.6, endTime: 1)
            ]
        )

        let result = try await coordinator.apply(
            to: base,
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 1
        )

        XCTAssertNil(result.speakerLabelWarning)
        XCTAssertEqual(result.fullText, base.fullText)
        XCTAssertEqual(result.segments.map(\.speaker), ["speaker_1", "speaker_2"])
        XCTAssertEqual(result.segments.map(\.text), ["hello missing", "world"])
        XCTAssertEqual(
            SpeakerTranscriptAligner.joinWordText(
                result.segments.map { (text: $0.text, hasLeadingSpace: $0.hasLeadingSpace) }
            ),
            base.fullText
        )
    }

    func testTwoSpeakerLabelsApplyWhenDecoderBoundaryWhitespaceDiffers() async throws {
        let fake = TextReconciliationDiarizer(
            intervals: [
                LocalDiarizationInterval(speakerID: "first", startTime: 0, endTime: 0.8),
                LocalDiarizationInterval(speakerID: "second", startTime: 0.8, endTime: 2)
            ]
        )
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = makeResult(
            text: "I paid $ 100 today.",
            timedWords: [
                TimedTranscriptWord(text: "I", startTime: 0, endTime: 0.2, hasLeadingSpace: false),
                TimedTranscriptWord(text: "paid", startTime: 0.3, endTime: 0.5),
                TimedTranscriptWord(text: "$100", startTime: 0.9, endTime: 1.2),
                TimedTranscriptWord(text: "today.", startTime: 1.3, endTime: 1.6)
            ]
        )

        let result = try await coordinator.apply(
            to: base,
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2
        )

        XCTAssertNil(result.speakerLabelWarning)
        XCTAssertEqual(result.fullText, base.fullText)
        XCTAssertEqual(result.segments.map(\.speaker), ["speaker_1", "speaker_2"])
        XCTAssertTrue(
            SpeakerTranscriptAligner.contentEquivalent(
                base.fullText,
                SpeakerTranscriptAligner.joinWordText(
                    result.segments.map { (text: $0.text, hasLeadingSpace: $0.hasLeadingSpace) }
                )
            )
        )
    }

    func testRealContentMismatchRetainsBaseTranscriptWithSpecificWarning() async throws {
        let fake = TextReconciliationDiarizer(
            intervals: [
                LocalDiarizationInterval(speakerID: "first", startTime: 0, endTime: 0.5),
                LocalDiarizationInterval(speakerID: "second", startTime: 0.5, endTime: 1)
            ]
        )
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = makeResult(
            text: "hello world",
            timedWords: [
                TimedTranscriptWord(text: "hello", startTime: 0, endTime: 0.4, hasLeadingSpace: false),
                TimedTranscriptWord(text: "there", startTime: 0.6, endTime: 1)
            ]
        )

        let result = try await coordinator.apply(
            to: base,
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 1
        )

        XCTAssertEqual(result.speakerLabelWarning, .textAlignmentMismatch)
        XCTAssertEqual(result.fullText, base.fullText)
        XCTAssertEqual(result.segments.map(\.speaker), [""])
    }

    private func makeResult(
        text: String,
        timedWords: [TimedTranscriptWord]
    ) -> TranscriptionResult {
        TranscriptionResult(
            fullText: text,
            segments: [TranscriptSegment(speaker: "", text: text, startTime: 0, endTime: 2)],
            processingTime: 0,
            chunkCount: 1,
            success: true,
            error: nil,
            timedWords: timedWords
        )
    }
}

private actor TextReconciliationDiarizer: LocalDiarizationModelManaging, LocalDiarizing {
    private let intervals: [LocalDiarizationInterval]

    init(intervals: [LocalDiarizationInterval] = [
        LocalDiarizationInterval(speakerID: "speaker", startTime: 0, endTime: 2)
    ]) {
        self.intervals = intervals
    }

    func modelStatus(for method: LocalDiarizationMethod) async -> LocalDiarizationModelStatus {
        LocalDiarizationModelStatus(method: method, state: .ready, fractionCompleted: 1)
    }

    func prepareModel(
        for method: LocalDiarizationMethod,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws {}

    func cancelModelPreparation(for method: LocalDiarizationMethod) async {}

    func unloadModel(for method: LocalDiarizationMethod) async {}

    func deleteModel(for method: LocalDiarizationMethod) async throws {}

    func diarize(
        audioURL: URL,
        method: LocalDiarizationMethod,
        audioDuration: TimeInterval?,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws -> LocalDiarizationResult {
        LocalDiarizationResult(intervals: intervals, audioDuration: audioDuration)
    }
}
