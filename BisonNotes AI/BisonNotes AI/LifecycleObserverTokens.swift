//
//  LifecycleObserverTokens.swift
//  BisonNotes AI
//
//  Shared holder for NotificationCenter block-observer tokens.
//

import Foundation

/// Holds `NotificationCenter` block-observer tokens outside of any actor
/// isolation, so a Swift 6 `deinit` — which is always nonisolated and therefore
/// cannot read actor-isolated stored properties — can still unregister them.
///
/// This matters because `NotificationCenter.addObserver(forName:object:queue:using:)`
/// retains the returned token and its block until `removeObserver` is called.
/// A `[weak self]` capture prevents a retain cycle but does *not* unregister the
/// observer: the registration, and the block, outlive the observing object and
/// keep firing for the lifetime of the process. Types that are constructed more
/// than once therefore accumulate dead registrations without this.
///
/// The unchecked conformance covers exactly one invariant: every access to
/// `tokens` is serialized by `lock`.
final class LifecycleObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init() {}

    /// Takes ownership of a token returned by `addObserver(forName:object:queue:using:)`.
    func add(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    /// Unregisters every held token. Safe to call more than once; the second
    /// call is a no-op because the list is drained under the lock first.
    func removeAll() {
        lock.lock()
        let current = tokens
        tokens.removeAll()
        lock.unlock()

        for token in current {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        removeAll()
    }
}
