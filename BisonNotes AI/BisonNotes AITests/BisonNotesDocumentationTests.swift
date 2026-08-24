import XCTest
@testable import BisonNotes_AI

final class BisonNotesDocumentationTests: XCTestCase {
    func testReleaseGuideURLUsesTheInstalledMajorMinorVersion() {
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "2.2").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-2/"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "2.4").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-4/"
        )
    }


    func testReleaseGuideURLKeepsTheSectionAnchor() {
        // The settings help button used to deep-link to the section that answers
        // the question; versioning the guide must not flatten that to the top of
        // the page.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.4",
                fragment: "bn24-ai"
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-4/#bn24-ai"
        )
    }

    func testUnreadableVersionFallsBackToTheUnversionedGuide() {
        // A pinned slug would silently send every user of the next release to an
        // old page; the unversioned landing page cannot go stale.
        for version in [nil, "", "banana", "2", "x.y"] {
            XCTAssertEqual(
                BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: version).absoluteString,
                "https://www.bisonnetworking.com/bisonnotes-ai/",
                "version \(version ?? "nil") should fall back"
            )
        }
    }

}
