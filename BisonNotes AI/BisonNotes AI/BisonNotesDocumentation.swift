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

    /// The guide section for a given screen, so in-app help keeps landing on the
    /// part that answers the question rather than the top of the page.
    static func releaseGuideURL(fragment: String) -> URL {
        releaseGuideURL(
            forMarketingVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            fragment: fragment
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
