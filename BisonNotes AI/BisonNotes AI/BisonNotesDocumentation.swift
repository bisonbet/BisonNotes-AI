//
//  BisonNotesDocumentation.swift
//  BisonNotes AI
//

import Foundation

/// Version-aware links to the WordPress release snapshots.
enum BisonNotesDocumentation {
    private static let releaseGuideBase = "https://www.bisonnetworking.com/bisonnotes-ai-v"
    private static let fallbackVersionSlug = "2-3"

    static var releaseGuideURL: URL {
        releaseGuideURL(forMarketingVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)
    }

    /// Builds the WordPress page URL from the app's major/minor marketing version.
    /// WordPress page slugs use hyphens for dotted versions, for example 2.3 -> 2-3.
    static func releaseGuideURL(forMarketingVersion marketingVersion: String?) -> URL {
        let versionSlug = versionSlug(for: marketingVersion) ?? fallbackVersionSlug
        return URL(string: "\(releaseGuideBase)\(versionSlug)/")!
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
