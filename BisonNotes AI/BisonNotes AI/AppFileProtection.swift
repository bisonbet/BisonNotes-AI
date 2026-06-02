import Foundation

enum AppFileProtection {
    static let sensitiveFileProtection: FileProtectionType = .complete

    static func apply(to url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: sensitiveFileProtection],
            ofItemAtPath: url.path
        )
    }

    static func applyRecursively(to directoryURL: URL) {
        apply(to: directoryURL)

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for case let url as URL in enumerator {
            apply(to: url)
        }
    }
}
