import Foundation

/// Coordinates ordinary library access with an exclusive maintenance window.
///
/// The gate is deliberately independent of Core Data and SQLite. Callers must
/// acquire normal access around ordinary source work and exclusive maintenance
/// around a source snapshot or migration operation. A queued exclusive
/// request prevents new normal leases from passing, so the source can drain
/// without starvation.
actor LibraryMaintenanceGate {
    enum AccessKind: Equatable, Sendable {
        case normal
        case exclusive
    }

    struct Status: Equatable, Sendable {
        let activeNormalCount: Int
        let waitingNormalCount: Int
        let waitingExclusiveCount: Int
        let maintenanceActive: Bool
    }

    /// A capability to use one access window. Releases are idempotent so
    /// cancellation cleanup and caller cleanup can safely overlap.
    final class Lease: @unchecked Sendable {
        private let id: UUID
        private let gate: LibraryMaintenanceGate

        fileprivate init(id: UUID, gate: LibraryMaintenanceGate) {
            self.id = id
            self.gate = gate
        }

        func release() async {
            await gate.release(id: id)
        }
    }

    private struct NormalWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    private struct ExclusiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    private var activeNormalCount = 0
    private var maintenanceActive = false
    private var activeLeases: [UUID: AccessKind] = [:]
    private var normalWaiters: [NormalWaiter] = []
    private var exclusiveWaiters: [ExclusiveWaiter] = []

    func acquireNormal() async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()

        if canGrantNormal {
            let lease = grant(id: id, kind: .normal)
            do {
                try Task.checkCancellation()
                return lease
            } catch {
                await lease.release()
                throw error
            }
        }

        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                normalWaiters.append(NormalWaiter(id: id, continuation: continuation))
                pumpWaiters()
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            await lease.release()
            throw error
        }
    }

    func acquireExclusive() async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()

        if canGrantExclusive {
            let lease = grant(id: id, kind: .exclusive)
            do {
                try Task.checkCancellation()
                return lease
            } catch {
                await lease.release()
                throw error
            }
        }

        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                exclusiveWaiters.append(
                    ExclusiveWaiter(id: id, continuation: continuation)
                )
                pumpWaiters()
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            await lease.release()
            throw error
        }
    }

    func withNormalAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquireNormal()
        do {
            let result = try await operation()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    func withExclusiveMaintenance<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquireExclusive()
        do {
            let result = try await operation()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    func status() -> Status {
        Status(
            activeNormalCount: activeNormalCount,
            waitingNormalCount: normalWaiters.count,
            waitingExclusiveCount: exclusiveWaiters.count,
            maintenanceActive: maintenanceActive
        )
    }

    private var canGrantNormal: Bool {
        !maintenanceActive && exclusiveWaiters.isEmpty && normalWaiters.isEmpty
    }

    private var canGrantExclusive: Bool {
        !maintenanceActive && activeNormalCount == 0 && exclusiveWaiters.isEmpty
    }

    private func grant(id: UUID, kind: AccessKind) -> Lease {
        activeLeases[id] = kind
        if kind == .normal {
            activeNormalCount += 1
        } else {
            maintenanceActive = true
        }
        return Lease(id: id, gate: self)
    }

    private func release(id: UUID) {
        guard let kind = activeLeases.removeValue(forKey: id) else {
            return
        }

        if kind == .normal {
            activeNormalCount -= 1
        } else {
            maintenanceActive = false
        }
        pumpWaiters()
    }

    private func cancelWaiter(id: UUID) {
        if let index = normalWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = normalWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            pumpWaiters()
            return
        }

        if let index = exclusiveWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = exclusiveWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            pumpWaiters()
            return
        }

        // Cancellation may race with a grant. Releasing here prevents a lease
        // from being stranded before the waiting task observes cancellation.
        release(id: id)
    }

    private func pumpWaiters() {
        guard !maintenanceActive else { return }

        if activeNormalCount == 0, !exclusiveWaiters.isEmpty {
            let waiter = exclusiveWaiters.removeFirst()
            let lease = grant(id: waiter.id, kind: .exclusive)
            waiter.continuation.resume(returning: lease)
            return
        }

        guard exclusiveWaiters.isEmpty else { return }

        while !normalWaiters.isEmpty {
            let waiter = normalWaiters.removeFirst()
            let lease = grant(id: waiter.id, kind: .normal)
            waiter.continuation.resume(returning: lease)
        }
    }
}
