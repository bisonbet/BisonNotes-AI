//
//  ShareImportAuthorization.swift
//  BisonNotes AI
//

import Foundation

enum ShareImportAuthorization {
    static let tokenFileName = ".share-import-token"

    static func isShareImportURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "bisonnotes"
            && url.host?.lowercased() == "share-import"
    }

    static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == "token" })?.value
    }

    static func consumeURLToken(from url: URL, in inboxURL: URL) -> Bool {
        guard isShareImportURL(url),
              let candidate = token(from: url),
              isValidToken(candidate),
              let stored = storedToken(in: inboxURL),
              candidate == stored else {
            return false
        }

        removeToken(in: inboxURL)
        return true
    }

    static func consumePendingToken(in inboxURL: URL) -> Bool {
        guard let stored = storedToken(in: inboxURL), isValidToken(stored) else {
            return false
        }

        removeToken(in: inboxURL)
        return true
    }

    static func removeToken(in inboxURL: URL) {
        try? FileManager.default.removeItem(at: tokenFileURL(in: inboxURL))
    }

    static func tokenFileURL(in inboxURL: URL) -> URL {
        inboxURL.appendingPathComponent(tokenFileName, isDirectory: false)
    }

    private static func storedToken(in inboxURL: URL) -> String? {
        let tokenURL = tokenFileURL(in: inboxURL)
        guard let data = try? Data(contentsOf: tokenURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        return token
    }

    private static func isValidToken(_ token: String) -> Bool {
        UUID(uuidString: token) != nil
    }
}
