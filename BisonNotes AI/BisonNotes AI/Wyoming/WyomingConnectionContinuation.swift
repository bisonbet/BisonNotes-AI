//
//  WyomingConnectionContinuation.swift
//  BisonNotes AI
//
//  Shared continuation holder for the Wyoming transport clients.
//

import Foundation

/// Holds the in-flight `connect()` continuation outside the client's actor
/// isolation.
///
/// Both Wyoming clients are `@MainActor`, so a Swift 6 `deinit` — always
/// nonisolated — cannot reach an isolated stored property. Without somewhere
/// unisolated to keep it, a client deallocated while a connect is still
/// suspended can never resume its continuation: the awaiting task stays
/// suspended for good and the runtime reports a leaked continuation.
///
/// `take()` is the single gate: it returns the pending continuation at most
/// once, so every resumption path (ready, failed, cancelled, disconnect,
/// deinit) is safe to call and only the first one wins.
final class WyomingConnectionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init() {}

    /// Stores a new continuation. If one was somehow already pending it is
    /// failed rather than dropped, so it can never be left unresumed.
    func store(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let existing = self.continuation
        self.continuation = continuation
        lock.unlock()

        existing?.resume(throwing: WyomingError.connectionFailed)
    }

    /// Removes and returns the pending continuation, if any. Subsequent calls
    /// return nil until another continuation is stored.
    func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }

        let current = continuation
        continuation = nil
        return current
    }

    /// Resumes the pending continuation, if any, with `result`.
    func finish(_ result: Result<Void, Error>) {
        take()?.resume(with: result)
    }

    var hasPendingContinuation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }
}
