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

    // MARK: - Markdown Stripping

    func testStrippingMarkdownLeavesIdentifiersIntact() {
        // CommonMark does not treat an underscore inside a word as emphasis, so
        // identifiers must survive intact wherever the underscores are flanked
        // by word characters.
        XCTAssertEqual("get_user_name".strippingMarkdown(), "get_user_name")
        XCTAssertEqual("MAX_RETRY_COUNT".strippingMarkdown(), "MAX_RETRY_COUNT")
        XCTAssertEqual("call get_user_name() first".strippingMarkdown(), "call get_user_name() first")
        XCTAssertEqual("_leading and trailing_ underscores".strippingMarkdown(), "leading and trailing underscores")
    }

    /// A dunder standing alone between spaces really is strong emphasis under
    /// CommonMark, so it is stripped. Documented rather than special-cased: the
    /// reported corruption was intraword underscores, and inventing an
    /// identifier-shaped exception here would diverge from the parser that
    /// renders the same text elsewhere in the app.
    func testStandaloneDunderIsStillTreatedAsEmphasis() {
        XCTAssertEqual("call __init__ first".strippingMarkdown(), "call init first")
    }

    func testStrippingMarkdownStillRemovesRealEmphasis() {
        XCTAssertEqual("this is _important_ today".strippingMarkdown(), "this is important today")
        XCTAssertEqual("this is __very__ clear".strippingMarkdown(), "this is very clear")
        XCTAssertEqual("this is **bold** text".strippingMarkdown(), "this is bold text")
        XCTAssertEqual("a *star* here".strippingMarkdown(), "a star here")
    }

}
