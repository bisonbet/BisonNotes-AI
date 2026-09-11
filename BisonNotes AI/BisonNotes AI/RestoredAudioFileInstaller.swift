import Foundation
import Darwin

enum RestoredAudioFileInstaller {
    /// Names every staging file this installer creates. `TemporaryFileCleanupService`
    /// matches on it, so the prefix is the contract between the two.
    static let stagingPrefix = "restore-"

    /// Copy first, then atomically install a sibling on the same filesystem.
    /// A failed copy or rename leaves the previous destination untouched.
    static func install(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        // Deliberately not a dot-file. The `defer` below covers every throwing path,
        // but a kill or a crash mid-copy leaves the staged bytes behind, and a hidden
        // name would be invisible to every reclaim path in the app:
        // `TemporaryFileCleanupService` enumerates with `.skipsHiddenFiles` and
        // AdvancedTroubleshootingService deliberately scans only supported
        // audio extensions; restore staging files must remain reclaimable by
        // TemporaryFileCleanupService instead.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        try staging.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                guard Darwin.rename(sourcePath, destinationPath) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}
