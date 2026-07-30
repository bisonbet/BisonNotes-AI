import XCTest
@testable import BisonNotes_AI

final class TranscriptCaptionTextCleanerTests: XCTestCase {
    func testRemovesTextualWebVTTCueIdentifiers() {
        let vtt = """
        WEBVTT

        chapter-1
        00:00:00.000 --> 00:00:02.000
        Opening remarks

        decision-point
        00:00:02.000 --> 00:00:04.000
        The team approved the proposal.
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: vtt)

        XCTAssertEqual(text, "Opening remarks\nThe team approved the proposal.")
    }

    func testPreservesTextSeparatedFromALaterTimingLine() {
        let vtt = """
        WEBVTT

        This line is spoken.

        00:00:02.000 --> 00:00:04.000
        This is another caption.
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: vtt)

        XCTAssertEqual(text, "This line is spoken.\nThis is another caption.")
    }
}
