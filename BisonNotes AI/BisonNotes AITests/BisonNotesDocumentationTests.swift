import XCTest
@testable import BisonNotes_AI

final class BisonNotesDocumentationTests: XCTestCase {
    func testReleaseGuideURLUsesTheInstalledMajorMinorVersion() {
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "2.5").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-5/"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "3.0").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v3-0/"
        )
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: "3.0.1").absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v3-0/",
            "a patch release uses its minor version's guide"
        )
    }

    func testReleaseGuideURLKeepsTheSectionAnchor() {
        // The settings help button used to deep-link to the section that answers
        // the question; versioning the guide must not flatten that to the top of
        // the page.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "3.0",
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v3-0/#bn-ai"
        )
    }

    func testSectionAnchorsAreTheSameInEveryRelease() {
        // Version-scoped anchors (`bn24-ai`) broke whenever a page redirected to a
        // different release's guide. One anchor per section survives a redirect.
        for version in ["3.0", "3.1", "4.0", "2.10.1"] {
            let url = BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: version,
                section: .aiSettings
            )
            XCTAssertEqual(url.fragment, "bn-ai", "version \(version)")
        }
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: "2.10.1",
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai-v2-10/#bn-ai"
        )
    }

    func testSectionAnchorIsKeptWhenTheVersionIsUnreadable() {
        // The unversioned page redirects to the current release's guide, which
        // carries the same anchors, so the reader still lands on the section.
        XCTAssertEqual(
            BisonNotesDocumentation.releaseGuideURL(
                forMarketingVersion: nil,
                section: .aiSettings
            ).absoluteString,
            "https://www.bisonnetworking.com/bisonnotes-ai/#bn-ai"
        )
    }

    func testUnreadableVersionFallsBackToTheUnversionedGuide() {
        // A pinned slug would silently send every user of the next release to an
        // old page; the unversioned page always points at the current release.
        for version in [nil, "", "banana", "2", "x.y"] {
            XCTAssertEqual(
                BisonNotesDocumentation.releaseGuideURL(forMarketingVersion: version).absoluteString,
                "https://www.bisonnetworking.com/bisonnotes-ai/",
                "version \(version ?? "nil") should fall back"
            )
        }
    }

    // MARK: - Guide files in the repository

    /// `docs/user-guide/` in this checkout, found relative to this source file.
    private func userGuideDirectory() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BisonNotes AI/BisonNotes AITests
            .deletingLastPathComponent() // BisonNotes AI
            .deletingLastPathComponent() // repository root
        let directory = repositoryRoot.appendingPathComponent("docs/user-guide", isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: repositoryRoot.appendingPathComponent("CLAUDE.md").path) else {
            throw XCTSkip("The repository is not readable from this test host")
        }
        return directory
    }

    private func guideHTML(forVersionSlug slug: String) throws -> String {
        let file = try userGuideDirectory().appendingPathComponent("bisonnotes-ai-v\(slug).html")
        guard FileManager.default.fileExists(atPath: file.path) else {
            XCTFail("docs/user-guide/\(file.lastPathComponent) is missing. Each app release needs its own user guide; see docs/user-guide/README.md.")
            return ""
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func testTheInstalledVersionHasAUserGuide() throws {
        // Help opens /bisonnotes-ai-v<major>-<minor>/, so shipping a version
        // without its guide sends every Help tap to a missing page — which is
        // what happened to 2.5.
        let version = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let slug = try XCTUnwrap(BisonNotesDocumentation.versionSlug(for: version))
        let html = try guideHTML(forVersionSlug: slug)
        guard !html.isEmpty else { return }

        for section in BisonNotesDocumentation.GuideSection.allCases {
            XCTAssertTrue(
                html.contains("id=\"\(section.anchor)\""),
                "the \(slug) guide has no id=\"\(section.anchor)\" for the \(section) help link"
            )
        }
    }

    func testEveryGuideKeepsTheAnchorsShippedBuildsOpen() throws {
        // A shipped build, or the unversioned page redirecting to any guide, can
        // open any of these anchors on any guide.
        let directory = try userGuideDirectory()
        let guides = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("bisonnotes-ai-v") && $0.hasSuffix(".html") }
        XCTAssertFalse(guides.isEmpty, "no guides found in docs/user-guide")

        for guide in guides {
            let html = try String(contentsOf: directory.appendingPathComponent(guide), encoding: .utf8)
            for section in BisonNotesDocumentation.GuideSection.allCases {
                for anchor in [section.anchor] + section.legacyAnchors {
                    XCTAssertTrue(html.contains("id=\"\(anchor)\""), "\(guide) is missing id=\"\(anchor)\"")
                }
            }
        }
    }
}
