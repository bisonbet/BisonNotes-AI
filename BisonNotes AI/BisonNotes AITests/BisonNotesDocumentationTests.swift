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


    func testReleaseGuideURLKeepsTheSectionAnchor() {
        // The settings help button used to deep-link to the section that answers
        // the question; versioning the guide must not flatten that to the top of
        // the page.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.3",
                fragment: "bn23-ai"
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-3/#bn23-ai"
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
