import Foundation
import Darwin

enum RestoredAudioFileInstaller {
    /// Copy first, then atomically install a sibling on the same filesystem.
    /// A failed copy or rename leaves the previous destination untouched.
    static func install(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
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
