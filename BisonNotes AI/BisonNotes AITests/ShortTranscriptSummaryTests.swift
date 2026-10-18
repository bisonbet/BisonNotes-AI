import XCTest
@testable import BisonNotes_AI

/// Transcripts this short are shown as-is, and Regenerate hides the Summary
/// Prompt picker for them, so both must use the same rule.
final class ShortTranscriptSummaryTests: XCTestCase {
    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    func testTheLimitIsInclusive() {
        XCTAssertTrue(SummaryManager.isShownAsIs(words(SummaryManager.shownAsIsWordLimit)))
        XCTAssertFalse(SummaryManager.isShownAsIs(words(SummaryManager.shownAsIsWordLimit + 1)))
    }

    func testSingleCharacterTokensAndBlankLinesDoNotCount() {
        let padded = words(SummaryManager.shownAsIsWordLimit)
            + String(repeating: " a I -\n\n", count: 20)
        XCTAssertTrue(SummaryManager.isShownAsIs(padded))
    }
}
