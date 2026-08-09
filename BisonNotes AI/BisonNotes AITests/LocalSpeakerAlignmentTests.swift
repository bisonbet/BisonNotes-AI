import XCTest
@testable import BisonNotes_AI

final class LocalSpeakerAlignmentTests: XCTestCase {
    func testReconstructsSentencePieceFragmentsAndPunctuation() {
        let tokens = [
            TimedTranscriptToken(text: "▁Hel", startTime: 0, endTime: 0.1),
            TimedTranscriptToken(text: "lo", startTime: 0.1, endTime: 0.2),
            TimedTranscriptToken(text: "▁world", startTime: 0.3, endTime: 0.4),
            TimedTranscriptToken(text: "▁,", startTime: 0.4, endTime: 0.45),
            TimedTranscriptToken(text: "▁how", startTime: 0.5, endTime: 0.6),
            TimedTranscriptToken(text: "ever", startTime: 0.6, endTime: 0.7),
            TimedTranscriptToken(text: "!", startTime: 0.7, endTime: 0.75)
        ]

        let words = SpeakerTranscriptAligner.reconstructWords(from: tokens)

        XCTAssertEqual(words.map(\.text), ["Hello", "world,", "however!"])
        XCTAssertEqual(words.map(\.hasLeadingSpace), [false, true, true])
        XCTAssertEqual(SpeakerTranscriptAligner.plainText(from: words), "Hello world, however!")
    }

    func testPreservesOrderAndDoesNotDropWords() {
        let words = [
            word("first", 0, 0.2),
            word("short", 0.25, 0.35),
            word("interjection", 0.4, 0.55),
            word("last", 0.6, 0.8)
        ]

        let result = SpeakerTranscriptAligner().align(
            words: words,
            intervals: [interval("a", 0, 1)],
            audioDuration: 1
        )

        XCTAssertEqual(result.segments.flatMap { $0.text.split(separator: " ").map(String.init) }, words.map(\.text))
        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1"])
    }

    func testChoosesStrongestTemporalOverlap() {
        let result = align(
            words: [word("word", 0.4, 0.8)],
            intervals: [interval("a", 0, 0.5), interval("b", 0.5, 1)]
        )

        XCTAssertEqual(result.segments.single?.speakerID, "speaker_2")
    }

    func testUsesMidpointThenEarliestStableOrderForTiesAndBoundaries() {
        let tied = align(
            words: [word("boundary", 0.4, 0.6)],
            intervals: [interval("first", 0, 0.5), interval("second", 0.5, 1)]
        )
        XCTAssertEqual(tied.segments.single?.speakerID, "speaker_1")

        let zeroLength = align(
            words: [word("at-boundary", 0.5, 0.5)],
            intervals: [interval("first", 0, 0.5), interval("second", 0.5, 1)]
        )
        XCTAssertEqual(zeroLength.segments.single?.speakerID, "speaker_1")
    }

    func testResolvesOverlappingSpeakersWithoutDuplicatingWord() {
        let result = align(
            words: [word("overlap", 0.25, 0.75)],
            intervals: [interval("quiet", 0, 0.4), interval("strong", 0.2, 0.9)]
        )

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.single?.speakerID, "speaker_2")
    }

    func testNormalizesSpeakerIDsByFirstTemporalAppearance() {
        let result = align(
            words: [word("early", 0.1, 0.2), word("late", 2.1, 2.2), word("again", 2.3, 2.4)],
            intervals: [
                interval("late-raw", 2, 3),
                interval("early-raw", 0, 1),
                interval("late-raw", 2.2, 2.5)
            ],
            duration: 3
        )

        XCTAssertEqual(result.normalizedIntervals.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_2"])
        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2"])
    }

    func testUsesUnknownForCredibleGapsInsteadOfInheritingPriorSpeaker() {
        let result = align(
            words: [word("known", 0.1, 0.2), word("gap", 1, 1.1), word("known-again", 2, 2.1)],
            intervals: [interval("a", 0, 0.5), interval("a", 1.8, 2.5)],
            duration: 3
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "Unknown", "speaker_1"])
    }

    func testMergesSameSpeakerOnlyAcrossNonMeaningfulSilence() {
        let result = SpeakerTranscriptAligner(meaningfulSilence: 0.5).align(
            words: [word("near", 0, 0.2), word("enough", 0.4, 0.6), word("apart", 1.2, 1.4)],
            intervals: [interval("a", 0, 2)],
            audioDuration: 2
        )

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map(\.text), ["near enough", "apart"])
    }

    func testClampsBadTimingsToAudioDurationAndKeepsText() {
        let result = align(
            words: [
                word("outside", -2, 10),
                word("reversed", 4, 2),
                TimedTranscriptWord(text: "malformed", startTime: .nan, endTime: .infinity)
            ],
            intervals: [interval("a", -1, 8)],
            duration: 5
        )

        XCTAssertEqual(result.segments.map(\.text), ["outside reversed", "malformed"])
        XCTAssertEqual(result.segments[0].startTime, 0)
        XCTAssertEqual(result.segments[0].endTime, 5)
        XCTAssertEqual(result.segments[1].speakerID, "Unknown")
        XCTAssertEqual(result.segments[1].startTime, 0)
        XCTAssertEqual(result.segments[1].endTime, 0)
    }

    func testEmptyASRAndEmptyTimelineAreSafe() {
        let empty = SpeakerTranscriptAligner().align(words: [], intervals: [], audioDuration: 10)
        XCTAssertTrue(empty.segments.isEmpty)
        XCTAssertTrue(empty.normalizedIntervals.isEmpty)

        let unknown = SpeakerTranscriptAligner().align(
            words: [word("text", 1, 2)],
            intervals: [],
            audioDuration: 10
        )
        XCTAssertEqual(unknown.segments.single?.speakerID, "Unknown")
    }

    func testNilAndMalformedTimingsRemainInOrderAsUnknown() {
        let result = SpeakerTranscriptAligner().align(
            words: [
                TimedTranscriptWord(text: "nil-time", startTime: nil, endTime: nil),
                TimedTranscriptWord(text: "nan-time", startTime: .nan, endTime: 1),
                word("valid", 1.1, 1.2)
            ],
            intervals: [interval("a", 1, 2)],
            audioDuration: 2
        )

        XCTAssertEqual(result.segments.map(\.text), ["nil-time nan-time", "valid"])
        XCTAssertEqual(result.segments[0].speakerID, "Unknown")
        XCTAssertEqual(result.segments[1].speakerID, "speaker_1")
    }

    func testOneSpeakerDoesNotCreateFakeMultiSpeakerFormatting() {
        let result = align(
            words: [word("only", 0, 0.2), word("speaker", 0.25, 0.5)],
            intervals: [interval("one-raw", 0, 1)]
        )

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.single?.speakerID, "speaker_1")
        XCTAssertEqual(result.segments.single?.text, "only speaker")
    }

    func testShortInterjectionsAreNotLostAtSpeakerTurns() {
        let result = align(
            words: [word("main", 0, 0.5), word("yes", 0.51, 0.56), word("continue", 0.57, 1)],
            intervals: [interval("a", 0, 0.5), interval("b", 0.5, 0.56), interval("a", 0.56, 1)]
        )

        XCTAssertEqual(result.segments.map(\.text), ["main", "yes", "continue"])
        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_1"])
    }

    func testNormalizedPlainTextRemainsEquivalentAfterAlignment() {
        let words = [
            TimedTranscriptWord(text: "Hello,", startTime: 0, endTime: 0.2, hasLeadingSpace: false),
            TimedTranscriptWord(text: "world!", startTime: 0.3, endTime: 0.5, hasLeadingSpace: true),
            TimedTranscriptWord(text: "Really?", startTime: 1, endTime: 1.2, hasLeadingSpace: true)
        ]
        let result = SpeakerTranscriptAligner().align(
            words: words,
            intervals: [interval("a", 0, 0.25), interval("b", 0.25, 0.8), interval("a", 0.8, 2)],
            audioDuration: 2
        )

        XCTAssertEqual(
            SpeakerTranscriptAligner.normalizedPlainText(from: words),
            SpeakerTranscriptAligner.normalizedPlainText(from: result.segments)
        )
    }

    private func align(
        words: [TimedTranscriptWord],
        intervals: [LocalDiarizationInterval],
        duration: TimeInterval = 2
    ) -> LocalSpeakerLabelingResult {
        SpeakerTranscriptAligner().align(
            words: words,
            intervals: intervals,
            audioDuration: duration
        )
    }

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedTranscriptWord {
        TimedTranscriptWord(text: text, startTime: start, endTime: end)
    }

    private func interval(_ speakerID: String, _ start: TimeInterval, _ end: TimeInterval) -> LocalDiarizationInterval {
        LocalDiarizationInterval(speakerID: speakerID, startTime: start, endTime: end)
    }
}

private extension Array where Element == LocalSpeakerLabeledSegment {
    var single: Element? {
        count == 1 ? first : nil
    }
}
