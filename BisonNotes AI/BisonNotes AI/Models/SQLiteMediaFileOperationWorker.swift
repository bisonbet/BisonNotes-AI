import CryptoKit
import Foundation

/// The process-local roots used to resolve the logical paths in a media
/// operation. The database stores only the root identifiers and relative
/// paths, never these sandbox URLs.
struct SQLiteMediaFileOperationRoots: Sendable {
    let source: [String: URL]
    let destination: [String: URL]
}

/// Executes one durable media operation outside the first-boot metadata
/// critical path. The database state changes bracket a verified, atomic file
/// install so a process kill leaves work that can be retried safely.
struct SQLiteMediaFileOperationWorker: Sendable {
    let store: SQLiteLibraryStore

    func run(
        operationID: String,
        roots: SQLiteMediaFileOperationRoots,
        at date: Date = Date()
    ) async throws -> SQLiteMediaFileOperation {
        try Task.checkCancellation()
        let claimed = try await store.claimMediaOperation(id: operationID, at: date)
        guard claimed.state != "completed" else { return claimed }

        do {
            let result = try await executeCopy(for: claimed, roots: roots)
            try Task.checkCancellation()
            return try await store.completeMediaOperation(
                id: claimed.id,
                byteLength: result.byteLength,
                sha256: result.sha256,
                at: date
            )
        } catch is CancellationError {
            _ = try? await store.requeueMediaOperation(id: claimed.id, at: date)
            throw CancellationError()
        } catch {
            _ = try? await store.failMediaOperation(id: claimed.id, at: date)
            throw error
        }
    }
}

private extension SQLiteMediaFileOperationWorker {
    func executeCopy(
        for operation: SQLiteMediaFileOperation,
        roots: SQLiteMediaFileOperationRoots
    ) async throws -> SQLiteMediaFileCopyResult {
        let urls = try Self.resolveURLs(for: operation, roots: roots)
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try SQLiteMediaFileCopyExecutor(
                sourceURL: urls.source,
                destinationURL: urls.destination,
                partialURL: urls.partial,
                expectedByteLength: operation.expectedByteLength,
                expectedSHA256: operation.expectedSHA256
            ).run()
        }.value
    }
}

private struct SQLiteMediaFileCopyResult: Equatable, Sendable {
    let byteLength: Int64
    let sha256: String
}

private struct SQLiteMediaFileCopyExecutor: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let partialURL: URL
    let expectedByteLength: Int64?
    let expectedSHA256: String?

    func run() throws -> SQLiteMediaFileCopyResult {
        let fileManager = FileManager.default
        do {
            guard let expectedByteLength,
                  let expectedSHA256 else {
                throw SQLiteMediaFileOperationError.operationConflict
            }

            if let destination = try Self.existingDestinationFingerprint(
                at: destinationURL
            ) {
                guard Self.matches(
                    destination,
                    byteLength: expectedByteLength,
                    sha256: expectedSHA256
                ) else {
                    throw SQLiteMediaFileOperationError.destinationConflict
                }
                try Self.removeIfPresent(partialURL, using: fileManager)
                return destination
            }

            try Self.verify(
                sourceURL,
                missingError: .sourceMissing,
                expectedByteLength: expectedByteLength,
                expectedSHA256: expectedSHA256
            )

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.removeIfPresent(partialURL, using: fileManager)
            try fileManager.copyItem(at: sourceURL, to: partialURL)

            try Self.verify(
                partialURL,
                missingError: .copyFailed,
                expectedByteLength: expectedByteLength,
                expectedSHA256: expectedSHA256
            )
            return try Self.publish(
                partialURL: partialURL,
                destinationURL: destinationURL,
                expectedByteLength: expectedByteLength,
                expectedSHA256: expectedSHA256,
                fileManager: fileManager
            )
        } catch {
            try? Self.removeIfPresent(partialURL, using: fileManager)
            throw error
        }
    }

    private static func publish(
        partialURL: URL,
        destinationURL: URL,
        expectedByteLength: Int64,
        expectedSHA256: String,
        fileManager: FileManager
    ) throws -> SQLiteMediaFileCopyResult {
        do {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        } catch {
            // A second worker or a recovered process may have published the
            // same file between the existence check and the rename.
            if let destination = try Self.existingDestinationFingerprint(
                at: destinationURL
            ) {
                guard Self.matches(
                    destination,
                    byteLength: expectedByteLength,
                    sha256: expectedSHA256
                ) else {
                    throw SQLiteMediaFileOperationError.destinationConflict
                }
                try Self.removeIfPresent(partialURL, using: fileManager)
                return destination
            }
            throw SQLiteMediaFileOperationError.copyFailed
        }

        let installed = try Self.fingerprint(
            at: destinationURL,
            missingError: .copyFailed
        )
        try Self.verify(
            installed,
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256
        )
        return installed
    }

    private static func fingerprint(
        at url: URL,
        missingError: SQLiteMediaFileOperationError
    ) throws -> SQLiteMediaFileCopyResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw missingError
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw missingError
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteLength: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            digest.update(data: chunk)
            byteLength += Int64(chunk.count)
        }
        return SQLiteMediaFileCopyResult(
            byteLength: byteLength,
            sha256: Self.hexDigest(digest.finalize())
        )
    }

    private static func existingDestinationFingerprint(
        at url: URL
    ) throws -> SQLiteMediaFileCopyResult? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try fingerprint(at: url, missingError: .destinationConflict)
    }

    private static func verify(
        _ result: SQLiteMediaFileCopyResult,
        expectedByteLength: Int64,
        expectedSHA256: String
    ) throws {
        guard Self.matches(
            result,
            byteLength: expectedByteLength,
            sha256: expectedSHA256
        ) else {
            throw SQLiteMediaFileOperationError.integrityMismatch
        }
    }

    private static func verify(
        _ url: URL,
        missingError: SQLiteMediaFileOperationError,
        expectedByteLength: Int64,
        expectedSHA256: String
    ) throws {
        let result = try fingerprint(at: url, missingError: missingError)
        try verify(
            result,
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256
        )
    }

    private static func removeIfPresent(
        _ url: URL,
        using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func matches(
        _ result: SQLiteMediaFileCopyResult,
        byteLength: Int64,
        sha256: String
    ) -> Bool {
        result.byteLength == byteLength &&
            result.sha256 == sha256.lowercased()
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension SQLiteMediaFileOperationWorker {
    struct ResolvedURLs: Sendable {
        let source: URL
        let destination: URL
        let partial: URL
    }

    static func resolveURLs(
        for operation: SQLiteMediaFileOperation,
        roots: SQLiteMediaFileOperationRoots
    ) throws -> ResolvedURLs {
        guard operation.operation == "copy",
              let sourceRoot = operation.sourceRoot,
              let sourceRelativePath = operation.sourceRelativePath,
              let destinationRoot = operation.destinationRoot,
              let destinationRelativePath = operation.destinationRelativePath else {
            throw SQLiteMediaFileOperationError.operationConflict
        }
        guard let sourceBase = roots.source[sourceRoot],
              let destinationBase = roots.destination[destinationRoot] else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }

        let source = try resolve(
            relativePath: sourceRelativePath,
            under: sourceBase
        )
        let destination = try resolve(
            relativePath: destinationRelativePath,
            under: destinationBase
        )
        let partialName = ".sqlite-media-\(safeOperationToken(operation.id)).partial"
        let partial = destination
            .deletingLastPathComponent()
            .appendingPathComponent(partialName, isDirectory: false)
        return ResolvedURLs(
            source: source,
            destination: destination,
            partial: partial
        )
    }

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

    static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    static func safeOperationToken(_ operationID: String) -> String {
        SHA256.hash(data: Data(operationID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
