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

    func testSectionAnchorsTrackTheInstalledVersion() {
        // The help button used to spell out `bn23-ai`, so once the app shipped 2.4
        // it opened the new guide at an anchor that only existed in the old one.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.4",
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-4/#bn24-ai"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.3",
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-3/#bn23-ai"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.10.1",
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-10/#bn210-ai",
            "the anchor prefix has to come from the same slug as the page"
        )
    }

    func testSectionAnchorIsDroppedWhenTheVersionIsUnreadable() {
        // The unversioned landing page carries none of the bnXX anchors.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: nil,
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai/"
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
