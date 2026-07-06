//
//  WebImportURLClassifier.swift
//  BisonNotes AI
//

import Foundation

struct WebImportURLClassifier {
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "www.youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }

    static func youtubeVideoID(from url: URL) -> String? {
        guard isYouTubeURL(url) else { return nil }

        if let host = url.host?.lowercased(),
           host == "youtu.be" || host == "www.youtu.be" {
            return cleanVideoID(url.pathComponents.dropFirst().first)
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let id = components.queryItems?.first(where: { $0.name == "v" })?.value,
           let cleaned = cleanVideoID(id) {
            return cleaned
        }

        return videoIDFromPath(url.pathComponents.filter { $0 != "/" })
    }

    private static func videoIDFromPath(_ pathComponents: [String]) -> String? {
        for marker in ["shorts", "embed", "live", "v"] {
            if let index = pathComponents.firstIndex(of: marker),
               pathComponents.indices.contains(index + 1),
               let cleaned = cleanVideoID(pathComponents[index + 1]) {
                return cleaned
            }
        }
        return nil
    }

    private static func cleanVideoID(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = value.unicodeScalars.prefix(32).filter { allowed.contains($0) }
        let id = String(String.UnicodeScalarView(scalars))
        return id.count >= 6 ? id : nil
    }
}
