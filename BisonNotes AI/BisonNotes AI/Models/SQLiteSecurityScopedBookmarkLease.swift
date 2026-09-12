import Foundation

/// Owns one resolved security-scoped bookmark for the duration of a file
/// operation. The resolved absolute URL remains process-local; callers persist
/// the original bookmark and logical root identifiers instead.
final class SQLiteSecurityScopedBookmarkLease: @unchecked Sendable {
    let url: URL
    let isStale: Bool

    private let lock = NSLock()
    private var hasStartedAccess = false

    init(
        bookmarkData: Data,
        options: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
    ) throws {
        var stale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw SQLiteSecurityScopedBookmarkError.unableToResolve
        }

        guard resolvedURL.isFileURL else {
            throw SQLiteSecurityScopedBookmarkError.resolvedURLIsNotFileURL
        }

        let normalizedURL = resolvedURL.standardizedFileURL
        self.url = normalizedURL
        self.isStale = stale
        self.hasStartedAccess = normalizedURL.startAccessingSecurityScopedResource()
    }

    /// Stops access at most once. The method is safe to call before `deinit`
    /// when the caller wants to release the provider scope early.
    func stopAccessing() {
        lock.lock()
        guard hasStartedAccess else {
            lock.unlock()
            return
        }
        hasStartedAccess = false
        lock.unlock()
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        stopAccessing()
    }
}

enum SQLiteSecurityScopedBookmarkError: LocalizedError, Equatable {
    case unableToResolve
    case resolvedURLIsNotFileURL

    var errorDescription: String? {
        switch self {
        case .unableToResolve:
            return "The saved file-provider bookmark could not be resolved."
        case .resolvedURLIsNotFileURL:
            return "The saved file-provider bookmark did not resolve to a file URL."
        }
    }
}
