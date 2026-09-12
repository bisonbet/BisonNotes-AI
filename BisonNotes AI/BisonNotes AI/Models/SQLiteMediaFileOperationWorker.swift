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
        rootRegistry: SQLiteMediaRootRegistry,
        at date: Date = Date()
    ) async throws -> SQLiteMediaFileOperation {
        guard let operation = try await store.mediaFileOperation(id: operationID) else {
            throw SQLiteMediaFileOperationError.operationNotFound
        }
        guard let sourceRoot = operation.sourceRoot,
              let destinationRoot = operation.destinationRoot else {
            throw SQLiteMediaFileOperationError.operationConflict
        }
        let roots = try rootRegistry.roots(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot
        )
        return try await run(operationID: operationID, roots: roots, at: date)
    }

    func run(
        operationID: String,
        roots: SQLiteMediaFileOperationRoots,
        at date: Date = Date()
    ) async throws -> SQLiteMediaFileOperation {
        try Task.checkCancellation()
        let claimed = try await store.claimMediaOperation(id: operationID, at: date)

        do {
            if claimed.state == "completed" {
                try await verifyPublishedCopy(for: claimed, roots: roots)
                return claimed
            }
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

/// Executes the copy phase of a provider archive restore. The source and
/// destination roots are resolved by the caller while any security-scoped
/// access is active; the potentially large file work is detached from the
/// application actor.
struct SQLiteArchiveRestoreCopyWorker: Sendable {
    let store: SQLiteLibraryStore

    func run(
        operationID: String,
        rootRegistry: SQLiteMediaRootRegistry,
        at date: Date = Date()
    ) async throws -> SQLiteArchiveRestoreOperation {
        guard let operation = try await store.archiveRestoreOperation(id: operationID) else {
            throw SQLiteArchiveRestoreError.operationNotFound
        }
        let roots = try rootRegistry.roots(
            sourceRoot: operation.sourceRoot,
            destinationRoot: operation.destinationRoot
        )
        let claimed = try await store.claimArchiveRestoreCopy(id: operationID, at: date)

        do {
            switch claimed.phase {
            case SQLiteArchiveRestorePhase.pending,
                 SQLiteArchiveRestorePhase.copyFailed,
                 SQLiteArchiveRestorePhase.copying:
                let result = try await executeCopy(for: claimed, roots: roots)
                try Task.checkCancellation()
                return try await store.completeArchiveRestoreCopy(
                    id: claimed.id,
                    byteLength: result.byteLength,
                    sha256: result.sha256,
                    at: date
                )
            case SQLiteArchiveRestorePhase.copied,
                 SQLiteArchiveRestorePhase.metadataFailed:
                try await verifyPublishedCopy(for: claimed, roots: roots)
                return claimed
            case SQLiteArchiveRestorePhase.committingMetadata,
                 SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.deletingSource,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed,
                 SQLiteArchiveRestorePhase.completed:
                return claimed
            default:
                throw SQLiteArchiveRestoreError.unsupportedPhase
            }
        } catch is CancellationError {
            _ = try? await store.requeueArchiveRestore(id: claimed.id, at: date)
            throw CancellationError()
        } catch {
            _ = try? await store.failArchiveRestoreCopy(id: claimed.id, at: date)
            throw error
        }
    }
}

/// Executes the final provider-source deletion phase after the recording
/// metadata acknowledgement has committed. Source and destination are
/// re-verified immediately before deletion, and an already-absent source is a
/// successful retry.
struct SQLiteArchiveRestoreSourceDeletionWorker: Sendable {
    let store: SQLiteLibraryStore

    func run(
        operationID: String,
        rootRegistry: SQLiteMediaRootRegistry,
        at date: Date = Date()
    ) async throws -> SQLiteArchiveRestoreOperation {
        guard let operation = try await store.archiveRestoreOperation(id: operationID) else {
            throw SQLiteArchiveRestoreError.operationNotFound
        }
        let roots = try rootRegistry.roots(
            sourceRoot: operation.sourceRoot,
            destinationRoot: operation.destinationRoot
        )
        let claimed = try await store.claimArchiveRestoreSourceDeletion(
            id: operationID,
            at: date
        )
        guard claimed.phase == SQLiteArchiveRestorePhase.deletingSource else {
            return claimed
        }

        do {
            try Task.checkCancellation()
            let urls = try Self.resolveURLs(for: claimed, roots: roots)
            try await Task.detached(priority: .utility) {
                try SQLiteArchiveRestoreSourceDeletionExecutor(
                    sourceURL: urls.source,
                    destinationURL: urls.destination,
                    expectedByteLength: claimed.expectedByteLength,
                    expectedSHA256: claimed.expectedSHA256
                ).run()
            }.value
            try Task.checkCancellation()
            return try await store.completeArchiveRestoreSourceDeletion(
                id: claimed.id,
                at: date
            )
        } catch is CancellationError {
            _ = try? await store.requeueArchiveRestore(id: claimed.id, at: date)
            throw CancellationError()
        } catch {
            _ = try? await store.failArchiveRestoreSourceDeletion(
                id: claimed.id,
                at: date
            )
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

    func verifyPublishedCopy(
        for operation: SQLiteMediaFileOperation,
        roots: SQLiteMediaFileOperationRoots
    ) async throws {
        let urls = try Self.resolveURLs(for: operation, roots: roots)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try SQLiteMediaFileCopyExecutor(
                sourceURL: urls.source,
                destinationURL: urls.destination,
                partialURL: urls.partial,
                expectedByteLength: operation.expectedByteLength,
                expectedSHA256: operation.expectedSHA256
            ).verifyInstalled()
        }.value
    }
}

private extension SQLiteArchiveRestoreCopyWorker {
    func executeCopy(
        for operation: SQLiteArchiveRestoreOperation,
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
                expectedSHA256: operation.expectedSHA256,
                coordinateSourceRead: true
            ).run()
        }.value
    }

    func verifyPublishedCopy(
        for operation: SQLiteArchiveRestoreOperation,
        roots: SQLiteMediaFileOperationRoots
    ) async throws {
        let urls = try Self.resolveURLs(for: operation, roots: roots)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try SQLiteMediaFileCopyExecutor(
                sourceURL: urls.source,
                destinationURL: urls.destination,
                partialURL: urls.partial,
                expectedByteLength: operation.expectedByteLength,
                expectedSHA256: operation.expectedSHA256
            ).verifyInstalled()
        }.value
    }

    static func resolveURLs(
        for operation: SQLiteArchiveRestoreOperation,
        roots: SQLiteMediaFileOperationRoots
    ) throws -> (source: URL, destination: URL, partial: URL) {
        guard let sourceBase = roots.source[operation.sourceRoot],
              let destinationBase = roots.destination[operation.destinationRoot] else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
        let source = try SQLiteMediaRootPathResolver.resolve(
            relativePath: operation.sourceRelativePath,
            under: sourceBase
        )
        let destination = try SQLiteMediaRootPathResolver.resolve(
            relativePath: operation.destinationRelativePath,
            under: destinationBase
        )
        let token = SHA256.hash(data: Data(operation.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".sqlite-archive-restore-\(token).partial")
        guard source.resolvingSymlinksInPath().standardizedFileURL
                != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteArchiveRestoreError.sourceDestinationAlias
        }
        return (source: source, destination: destination, partial: partial)
    }
}

private extension SQLiteArchiveRestoreSourceDeletionWorker {
    static func resolveURLs(
        for operation: SQLiteArchiveRestoreOperation,
        roots: SQLiteMediaFileOperationRoots
    ) throws -> (source: URL, destination: URL) {
        guard let sourceBase = roots.source[operation.sourceRoot],
              let destinationBase = roots.destination[operation.destinationRoot] else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
        let source = try SQLiteMediaRootPathResolver.resolve(
            relativePath: operation.sourceRelativePath,
            under: sourceBase
        )
        let destination = try SQLiteMediaRootPathResolver.resolve(
            relativePath: operation.destinationRelativePath,
            under: destinationBase
        )
        return (source: source, destination: destination)
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
    let coordinateSourceRead: Bool

    init(
        sourceURL: URL,
        destinationURL: URL,
        partialURL: URL,
        expectedByteLength: Int64?,
        expectedSHA256: String?,
        coordinateSourceRead: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.partialURL = partialURL
        self.expectedByteLength = expectedByteLength
        self.expectedSHA256 = expectedSHA256
        self.coordinateSourceRead = coordinateSourceRead
    }

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
            try Self.copySource(
                from: sourceURL,
                to: partialURL,
                coordinateRead: coordinateSourceRead,
                using: fileManager
            )

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

    func verifyInstalled() throws {
        guard let expectedByteLength,
              let expectedSHA256 else {
            throw SQLiteMediaFileOperationError.operationConflict
        }
        try Self.verify(
            destinationURL,
            missingError: .copyFailed,
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256
        )
    }

    func verifySource() throws {
        guard let expectedByteLength,
              let expectedSHA256 else {
            throw SQLiteMediaFileOperationError.operationConflict
        }
        try Self.verify(
            sourceURL,
            missingError: .sourceMissing,
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256
        )
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

    private static func copySource(
        from sourceURL: URL,
        to destinationURL: URL,
        coordinateRead: Bool,
        using fileManager: FileManager
    ) throws {
        guard coordinateRead else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return
        }

        var coordinatorError: NSError?
        var operationError: Error?
        var didCopy = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                didCopy = true
            } catch {
                operationError = error
            }
        }

        if let operationError {
            throw operationError
        }
        if coordinatorError != nil || !didCopy {
            throw SQLiteMediaFileOperationError.copyFailed
        }
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

private struct SQLiteArchiveRestoreSourceDeletionExecutor: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let expectedByteLength: Int64
    let expectedSHA256: String

    func run() throws {
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
                != destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteArchiveRestoreError.sourceDestinationAlias
        }

        let verifier = SQLiteMediaFileCopyExecutor(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            partialURL: destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".sqlite-archive-delete-verification.partial"),
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256
        )
        do {
            try verifier.verifyInstalled()
        } catch let error as SQLiteMediaFileOperationError {
            throw Self.mapVerificationError(error, destination: true)
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        do {
            try verifier.verifySource()
        } catch let error as SQLiteMediaFileOperationError {
            throw Self.mapVerificationError(error, destination: false)
        }

        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            try? fileManager.removeItem(at: coordinatedURL)
        }

        if fileManager.fileExists(atPath: sourceURL.path) {
            // Some local file systems reject NSFileCoordinator coordination
            // without a presenter (for example, a plain test directory), and
            // some providers return a coordinated URL that is not removable
            // until the scope is refreshed. Re-verify the exact source before
            // this idempotent fallback; a provider error still leaves the
            // journal retryable.
            do {
                try verifier.verifySource()
                try fileManager.removeItem(at: sourceURL)
            } catch {
                throw SQLiteArchiveRestoreError.sourceDeletionFailed
            }
        }
        if fileManager.fileExists(atPath: sourceURL.path) {
            throw SQLiteArchiveRestoreError.sourceDeletionFailed
        }
    }

    private static func mapVerificationError(
        _ error: SQLiteMediaFileOperationError,
        destination: Bool
    ) -> SQLiteArchiveRestoreError {
        switch error {
        case .sourceMissing:
            return .sourceMissing
        case .destinationConflict:
            return .destinationConflict
        case .integrityMismatch:
            return .integrityMismatch
        case .copyFailed:
            return destination ? .destinationConflict : .sourceDeletionFailed
        default:
            return .sourceDeletionFailed
        }
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
        try SQLiteMediaRootPathResolver.resolve(relativePath: relativePath, under: root)
    }

    static func safeOperationToken(_ operationID: String) -> String {
        SHA256.hash(data: Data(operationID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
