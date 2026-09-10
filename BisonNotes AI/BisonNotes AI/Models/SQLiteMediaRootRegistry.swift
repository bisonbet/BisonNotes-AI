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

    func sourceURL(
        root: String,
        relativePath: String
    ) throws -> URL {
        try resolve(
            root: root,
            relativePath: relativePath,
            from: sourceRoots
        )
    }

    func destinationURL(
        root: String,
        relativePath: String
    ) throws -> URL {
        try resolve(
            root: root,
            relativePath: relativePath,
            from: destinationRoots
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

    func resolve(
        root: String,
        relativePath: String,
        from roots: [String: URL]
    ) throws -> URL {
        try SQLiteMediaFileOperationValidation.root(root)
        try SQLiteMediaFileOperationValidation.relativePath(relativePath)
        guard let baseURL = roots[root] else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
        return try SQLiteMediaRootPathResolver.resolve(
            relativePath: relativePath,
            under: baseURL
        )
    }
}

enum SQLiteMediaRootPathResolver {
    static func resolve(relativePath: String, under root: URL) throws -> URL {
        try SQLiteMediaFileOperationValidation.relativePath(relativePath)
        guard root.isFileURL, !root.path.isEmpty else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }

        let normalizedRoot = root.standardizedFileURL
        let candidate = normalizedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard isWithin(candidate, root: normalizedRoot) else {
            throw SQLiteMediaFileOperationError.invalidRelativePath
        }

        let resolvedRoot = normalizedRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedCandidate = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isWithin(resolvedCandidate, root: resolvedRoot) else {
            throw SQLiteMediaFileOperationError.invalidRelativePath
        }
        return candidate
    }

    private static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
