import Foundation

enum AppFileProtection {
    // .completeUntilFirstUserAuthentication keeps files encrypted at rest but
    // available once the user has unlocked the device after boot. Background
    // recording, transcription, and Core Data writes can fire while the device
    // is locked again later, and .complete would make those reads/writes fail.
    static let sensitiveFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

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
