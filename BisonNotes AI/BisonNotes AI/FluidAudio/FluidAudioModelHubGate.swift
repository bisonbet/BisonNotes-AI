import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Serializes app-owned FluidAudio Hub operations that temporarily change the
/// process-wide `ModelHub.offlineMode` switch.
///
/// FluidAudio exposes the switch as global mutable state. Actor isolation on an
/// individual model provider is insufficient because actors are reentrant at
/// suspension points and Parakeet and diarization use different owners.
actor FluidAudioModelHubGate {
    enum AccessMode: Sendable {
        case online
        case offline
    }

    static let shared = FluidAudioModelHubGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func withExclusiveAccess<T: Sendable>(
        mode: AccessMode,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()

        #if canImport(FluidAudio)
        let previousOfflineMode = ModelHub.offlineMode
        ModelHub.offlineMode = mode == .offline
        defer { ModelHub.offlineMode = previousOfflineMode }
        #endif

        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isLocked else {
            isLocked = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }
}
