//
//  BisonNotesDocumentation.swift
//  BisonNotes AI
//

import Foundation

/// Links to the user guide for the installed release.
///
/// Every app release has its own complete guide at `/bisonnotes-ai-v<major>-<minor>/`,
/// and `/bisonnotes-ai/` redirects to the guide for the current App Store release.
/// `docs/user-guide/README.md` describes the publishing process.
enum BisonNotesDocumentation {
    private static let releaseGuideBase = "https://www.bisonnetworking.com/bisonnotes-ai-v"

    /// Where to send a reader whose installed version cannot be read. It redirects
    /// to the current release's guide, so it cannot go stale the way a pinned slug
    /// would the moment the app ships its next release.
    private static let unversionedGuide = "https://www.bisonnetworking.com/bisonnotes-ai/"

    static var releaseGuideURL: URL {
        releaseGuideURL(forMarketingVersion: installedMarketingVersion)
    }

    /// A section of the guide, named the way a screen thinks about it.
    ///
    /// The raw value is the section's anchor without the `bn-` prefix. Anchors
    /// are the same in every release's guide, so a link keeps working when the
    /// unversioned page redirects to another release. Builds 2.3–2.5 shipped
    /// with version-scoped anchors (`bn25-ai`); the guides keep those as aliases,
    /// and `legacyAnchors` lists them so the guide tests can check they survive.
    enum GuideSection: String, CaseIterable {
        case aiSettings = "ai"

        var anchor: String { "bn-\(rawValue)" }

        /// Version-scoped anchors that shipped builds still open.
        var legacyAnchors: [String] {
            switch self {
            case .aiSettings:
                return ["bn23-ai", "bn24-ai", "bn25-ai"]
            }
        }
    }

    /// The guide section for a given screen, so in-app help keeps landing on the
    /// part that answers the question rather than the top of the page.
    static func releaseGuideURL(section: GuideSection) -> URL {
        releaseGuideURL(forMarketingVersion: installedMarketingVersion, section: section)
    }

    static func releaseGuideURL(
        forMarketingVersion marketingVersion: String?,
        section: GuideSection
    ) -> URL {
        releaseGuideURL(forMarketingVersion: marketingVersion, fragment: section.anchor)
    }

    /// Builds the WordPress page URL from the app's major/minor marketing version.
    /// WordPress page slugs use hyphens for dotted versions, for example 2.4 -> 2-4.
    static func releaseGuideURL(
        forMarketingVersion marketingVersion: String?,
        fragment: String? = nil
    ) -> URL {
        let base: String
        if let versionSlug = versionSlug(for: marketingVersion) {
            base = "\(releaseGuideBase)\(versionSlug)/"
        } else {
            base = unversionedGuide
        }

        let absolute = fragment.map { "\(base)#\($0)" } ?? base

        // Every component is either a compile-time constant or a slug already
        // validated as digits, so this cannot fail — but fall back rather than
        // trapping if that ever stops being true.
        return URL(string: absolute) ?? URL(string: unversionedGuide)!
    }

    /// The guide's slug for a marketing version, for example `3-0` for 3.0.1.
    static func versionSlug(for marketingVersion: String?) -> String? {
        guard let marketingVersion else { return nil }

        let components = marketingVersion.split(separator: ".")
        guard components.count >= 2,
              Int(String(components[0])) != nil,
              Int(String(components[1])) != nil else {
            return nil
        }

        return "\(components[0])-\(components[1])"
    }

    private static var installedMarketingVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
