import XCTest
@testable import BisonNotes_AI

final class TranscriptEditorCloseBehaviorTests: XCTestCase {
    func testSnapshotTracksOnlyEditableTranscriptContent() {
        let originalSegment = TranscriptSegment(
            speaker: "speaker_1",
            text: "Original text",
            startTime: 0,
            endTime: 1
        )
        let baseline = TranscriptEditorSnapshot(
            segments: [originalSegment],
            speakerMappings: ["speaker_1": "Alex"]
        )

        let sameContentWithNewSegmentIdentity = TranscriptSegment(
            speaker: "speaker_1",
            text: "Original text",
            startTime: 0,
            endTime: 1
        )
        let equivalent = TranscriptEditorSnapshot(
            segments: [sameContentWithNewSegmentIdentity],
            speakerMappings: ["speaker_1": "Alex"]
        )

        XCTAssertEqual(baseline, equivalent)
    }

    func testSnapshotChangesForSegmentTextAndSpeakerMappingEdits() {
        let segment = TranscriptSegment(
            speaker: "speaker_1",
            text: "Original text",
            startTime: 0,
            endTime: 1
        )
        let baseline = TranscriptEditorSnapshot(
            segments: [segment],
            speakerMappings: ["speaker_1": "Alex"]
        )

        let editedText = TranscriptEditorSnapshot(
            segments: [
                TranscriptSegment(
                    speaker: "speaker_1",
                    text: "Edited text",
                    startTime: 0,
                    endTime: 1
                )
            ],
            speakerMappings: ["speaker_1": "Alex"]
        )
        let editedSpeaker = TranscriptEditorSnapshot(
            segments: [segment],
            speakerMappings: ["speaker_1": "Jordan"]
        )

        XCTAssertNotEqual(baseline, editedText)
        XCTAssertNotEqual(baseline, editedSpeaker)
    }
}
