import Foundation

/// Resolves logical media roots to process-local sandbox URLs.
///
/// Root identifiers are the only values that cross the SQLite boundary. The
/// registry is supplied by the eventual app integration, so this isolated
/// slice does not choose or mutate production directories.
struct SQLiteMediaRootRegistry: Sendable {
    private let sourceRoots: [String: URL]
    private let destinationRoots: [String: URL]

    init(
        sourceRoots: [String: URL],
        destinationRoots: [String: URL]
    ) throws {
        self.sourceRoots = try Self.validate(sourceRoots)
        self.destinationRoots = try Self.validate(destinationRoots)
    }

    func roots(
        sourceRoot: String,
        destinationRoot: String
    ) throws -> SQLiteMediaFileOperationRoots {
        try SQLiteMediaFileOperationValidation.root(sourceRoot)
        try SQLiteMediaFileOperationValidation.root(destinationRoot)
        guard let source = sourceRoots[sourceRoot],
              let destination = destinationRoots[destinationRoot] else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
        return SQLiteMediaFileOperationRoots(
            source: [sourceRoot: source],
            destination: [destinationRoot: destination]
        )
    }
}

private extension SQLiteMediaRootRegistry {
    static func validate(_ roots: [String: URL]) throws -> [String: URL] {
        guard !roots.isEmpty else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }

        var normalizedRoots: [String: URL] = [:]
        for (identifier, url) in roots {
            try SQLiteMediaFileOperationValidation.root(identifier)
            let normalizedURL = url.standardizedFileURL
            guard url.isFileURL,
                  !normalizedURL.path.isEmpty,
                  normalizedURL.path != "/" else {
                throw SQLiteMediaFileOperationError.invalidRoot
            }
            normalizedRoots[identifier] = normalizedURL
        }
        return normalizedRoots
    }
}
