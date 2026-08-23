import XCTest
@testable import BisonNotes_AI

final class BisonNotesDocumentationTests: XCTestCase {
    func testReleaseGuideURLUsesTheInstalledMajorMinorVersion() {
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "2.2").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-2/"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "2.3").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-3/"
        )
    }

    func testReleaseGuideURLFallsBackToTheCurrentReleaseForMissingVersion() {
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: nil).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-3/"
        )
    }
}
