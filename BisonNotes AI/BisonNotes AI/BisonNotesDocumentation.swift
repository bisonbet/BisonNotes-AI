//
//  BisonNotesDocumentation.swift
//  BisonNotes AI
//

import Foundation

/// Version-aware links to the WordPress release snapshots.
enum BisonNotesDocumentation {
    private static let releaseGuideBase = "https://www.bisonnetworking.com/bisonnotes-ai-v"

    /// Where to send a reader whose installed version cannot be read. The
    /// unversioned landing page always exists, so this cannot go stale the way a
    /// pinned slug would the moment the app ships its next release.
    private static let unversionedGuide = "https://www.bisonnetworking.com/bisonnotes-ai/"

    static var releaseGuideURL: URL {
        releaseGuideURL(forMarketingVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)
    }

    /// A section of the guide, named the way a screen thinks about it.
    ///
    /// The anchors themselves are version-scoped — `bn23-ai` in the 2.3 guide,
    /// `bn24-ai` in the 2.4 one — so a call site that spells one out keeps opening
    /// the previous release's anchor the moment the app ships a new version. The
    /// caller names the section; the installed version supplies the prefix.
    enum GuideSection: String {
        case aiSettings = "ai"
    }

    /// The guide section for a given screen, so in-app help keeps landing on the
    /// part that answers the question rather than the top of the page.
    static func releaseGuideURL(section: GuideSection) -> URL {
        releaseGuideURL(
            forMarketingVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            section: section
        )
    }

    static func releaseGuideURL(
        forMarketingVersion marketingVersion: String?,
        section: GuideSection
    ) -> URL {
        guard let versionSlug = versionSlug(for: marketingVersion) else {
            // The unversioned landing page carries none of these anchors, so a
            // fragment there would land the reader nowhere.
            return releaseGuideURL(forMarketingVersion: marketingVersion)
        }

        let anchorPrefix = "bn\(versionSlug.replacingOccurrences(of: "-", with: ""))"
        return releaseGuideURL(
            forMarketingVersion: marketingVersion,
            fragment: "\(anchorPrefix)-\(section.rawValue)"
        )
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

    private static func versionSlug(for marketingVersion: String?) -> String? {
        guard let marketingVersion else { return nil }

        let components = marketingVersion.split(separator: ".")
        guard components.count >= 2,
              Int(String(components[0])) != nil,
              Int(String(components[1])) != nil else {
            return nil
        }

        return "\(components[0])-\(components[1])"
    }
}
